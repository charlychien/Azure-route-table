#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# 在指定的 Route Table 上,為每一個 Private Endpoint 私網 IP 建立一條 /32 UDR,
# 把 next hop 都指到指定的 Virtual Appliance (NVA) IP。
#
# 適用情境:
#   spoke VNet 的 PE subnet 已經設好 privateEndpointNetworkPolicies=RouteTableEnabled,
#   但 NVA 上聯的 LAN NIC 所掛的 route table 還沒有指向 PE 的 /32 路由,
#   所以從 NVA 出去回傳 PE 的封包會走錯路 (例如跑去 default 0.0.0.0/0 → AzFW)。
#   這支腳本一次把所有 PE 的 /32 加進指定 route table。
#
# 必填變數:
#   ROUTE_TABLE_ID  目標 route table 的完整 resource ID
#                   /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/routeTables/<name>
#   NVA_IP          Virtual Appliance 的 IP (Next Hop)   (APPLY=2 還原模式不需要)
#
# 選填:
#   PE_IPS          一或多個 PE 私網 IP,空白或逗號分隔 (最高優先序)
#   PE_IPS_FILE    指向一份每行一個 IP 的檔案 (其次優先序)
#                   未提供 PE_IPS / PE_IPS_FILE 時,自動讀取腳本所在目錄的
#                   'pe ip.txt' (檔名固定,可含 header / 註解 / 空行,腳本只挑
#                   合法 IPv4 的行)。要在不同地方重複使用,把腳本與 'pe ip.txt'
#                   一起放到目標資料夾即可。
#   APPLY           0 (預設) = dry-run
#                   1        = 一次 PUT 套用變更 (執行前自動備份)
#                   2        = 從備份還原 route table 為先前狀態 (rollback)
#   ROUTE_PREFIX    路由名稱前綴 (預設 'pe-')
#                   每條路由實際名稱 = <ROUTE_PREFIX><ip-with-dashes>,例如 pe-10-0-92-4
#   BACKUP_DIR      備份目錄 (預設 ./pe-routes-backups)
#                   每次 run 都會產生兩個檔:
#                     <RT_NAME>-<timestamp>-before.json  → 變更前的完整 route table
#                     <RT_NAME>-<timestamp>-after.json   → 此次要 PUT 上去的完整內容
#                   APPLY=0/1 還會更新:
#                     <RT_NAME>-latest-before.json       → 最近一次變更前 (APPLY=2 預設讀這個)
#                     <RT_NAME>-latest-after.json        → 最近一次套用上去的目標
#   BACKUP_FILE     APPLY=2 還原時要還原成的備份檔絕對路徑 (預設 latest-before.json)
#
# Usage:
#   # 使用內嵌的預設 PE IP 清單 (dry-run)
#   NVA_IP=10.20.0.4 \
#   ROUTE_TABLE_ID=/subscriptions/<sub>/resourceGroups/rg-hub/providers/Microsoft.Network/routeTables/rt-nva-lan \
#     ./add-pe-routes.sh
#
#   # 真的下指令 (執行前會把現狀存到 ./pe-routes-backups/)
#   APPLY=1 NVA_IP=... ROUTE_TABLE_ID=... ./add-pe-routes.sh
#
#   # 還原 (rollback) 為最近一次變更前的狀態
#   APPLY=2 ROUTE_TABLE_ID=... ./add-pe-routes.sh
#
#   # 還原為指定的備份檔
#   APPLY=2 BACKUP_FILE=./pe-routes-backups/rt-foo-20260611T143000.json \
#     ROUTE_TABLE_ID=... ./add-pe-routes.sh
#
#   # 自帶 IP 清單覆寫內嵌預設
#   PE_IPS="10.0.92.4 10.0.93.132" NVA_IP=... ROUTE_TABLE_ID=... ./add-pe-routes.sh
#
# 限制 (本腳本本身不設上限,真正 ceiling 在 Azure 端):
#   - 單張 Route Table 預設最多 400 條路由,可開 support case 提升至 1000
#     https://learn.microsoft.com/azure/azure-resource-manager/management/azure-subscription-service-limits#networking-limits
#   - 計算量是「該 RT 上所有路由總和」,包含原本不是 PE 的路由
#   - 留意肥型 PE (例如 AMPLS 一個 PE 就佔 ~11 條 /32),要把它們先算進去
#
# 行為:
#   - 只用「一次 PUT」整張 Route Table (透過 az rest),不再逐筆 az network route-table route create
#   - 與本次 PE_IPS 對應的 route 名稱 (${ROUTE_PREFIX}<ip-with-dashes>) 會被覆寫
#   - 其它 routes (含名稱不衝突的舊 pe-*、預設 0.0.0.0/0 等) 完全保留不動
#   - 依賴: jq、az CLI
# ------------------------------------------------------------------------------
set -euo pipefail

# Git Bash / MSYS 不要把以 '/' 開頭的參數當路徑轉換,否則 Azure resource ID 會壞掉
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

APPLY="${APPLY:-0}"
ROUTE_PREFIX="${ROUTE_PREFIX:-pe-}"

# --- 必填參數檢查 -------------------------------------------------------------
[[ -z "${ROUTE_TABLE_ID:-}" ]] && { echo "ERROR: 必須提供 ROUTE_TABLE_ID"; exit 1; }
if [[ "$APPLY" != "2" ]]; then
  [[ -z "${NVA_IP:-}" ]]      && { echo "ERROR: 必須提供 NVA_IP (APPLY=2 還原模式不需要)"; exit 1; }
fi

# 解析 Route Table ID -> subscription / RG / name
RT_SUB=$(echo "$ROUTE_TABLE_ID"  | awk -F'/' '{print $3}')
RT_RG=$(echo "$ROUTE_TABLE_ID"   | awk -F'/' '{print $5}')
RT_NAME=$(echo "$ROUTE_TABLE_ID" | awk -F'/' '{print $NF}')
if [[ -z "$RT_SUB" || -z "$RT_RG" || -z "$RT_NAME" ]]; then
  echo "ERROR: ROUTE_TABLE_ID 格式不正確: $ROUTE_TABLE_ID"
  exit 1
fi

# 預設 PE IP 清單檔:腳本所在目錄底下的 'pe ip.txt'
# 把腳本 + 'pe ip.txt' 一起放到不同資料夾,就能在不同 case 重複使用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_PE_IPS_FILE="$SCRIPT_DIR/pe ip.txt"

# 蒐集 PE IP (APPLY=2 還原模式不需要,跳過) ------------------------------------
PE_IP_ARR=()
ipv4_re='^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$'

if [[ "$APPLY" != "2" ]]; then
  ips_raw=""
  if [[ -n "${PE_IPS:-}" ]]; then
    ips_raw="$PE_IPS"
  else
    # PE_IPS_FILE 沒給就用腳本目錄底下的 'pe ip.txt'
    pe_ips_file="${PE_IPS_FILE:-$DEFAULT_PE_IPS_FILE}"
    if [[ ! -f "$pe_ips_file" ]]; then
      echo "ERROR: 找不到 PE IP 清單檔: $pe_ips_file"
      echo "       提示:把 'pe ip.txt' 放到腳本所在目錄 ($SCRIPT_DIR),"
      echo "             或設定 PE_IPS / PE_IPS_FILE 環境變數。"
      exit 1
    fi
    # 只挑合法 IPv4 行,自動忽略 header / 註解 / 空白行
    ips_raw=$(grep -E '^[[:space:]]*([0-9]+\.){3}[0-9]+[[:space:]]*$' "$pe_ips_file" | tr '\n' ' ')
    echo "INFO: 讀取 PE IP 清單: $pe_ips_file"
  fi

  ips_clean=$(echo "$ips_raw" | tr ',' ' ' | tr -s ' ')
  read -r -a PE_IP_ARR <<< "$ips_clean"
  if [[ ${#PE_IP_ARR[@]} -eq 0 ]]; then
    echo "ERROR: PE IP 清單是空的 (來源: ${PE_IPS:+PE_IPS env}${pe_ips_file:-})"; exit 1
  fi

  for ip in "${PE_IP_ARR[@]}"; do
    if ! [[ $ip =~ $ipv4_re ]]; then
      echo "ERROR: 不像合法 IPv4: '$ip'"; exit 1
    fi
  done

  if ! [[ $NVA_IP =~ $ipv4_re ]]; then
    echo "ERROR: NVA_IP 不像合法 IPv4: '$NVA_IP'"; exit 1
  fi
fi

# --- Azure CLI 登入確認 -------------------------------------------------------
command -v az >/dev/null 2>&1 || { echo "ERROR: 找不到 az CLI"; exit 1; }
if ! az account show >/dev/null 2>&1; then
  echo "ERROR: Azure CLI 尚未登入,請先執行: az login"; exit 1
fi

# --- 抓取現有 route table -----------------------------------------------------
command -v jq >/dev/null 2>&1 || { echo "ERROR: 找不到 jq"; exit 1; }

api_ver="2024-05-01"

echo "==> Target route table: $RT_NAME (rg=$RT_RG, sub=$RT_SUB)"
if [[ "$APPLY" == "2" ]]; then
  echo "==> Mode:               RESTORE (APPLY=2)"
else
  echo "==> Next hop (NVA):     $NVA_IP"
  echo "==> PE IPs to manage:   ${#PE_IP_ARR[@]} 個"
fi
echo ""

# 用 az rest GET 拿「原生 ARM JSON」(含完整 .properties.routes 巢狀結構),
# 不要用 az network route-table show — 它會把 routes/disableBgpRoutePropagation
# 等欄位 flatten 到頂層,導致後面 jq 抓不到 .properties.routes
current_json=$(az rest --method GET \
  --url "https://management.azure.com${ROUTE_TABLE_ID}?api-version=${api_ver}" \
  --subscription "$RT_SUB")

before_count=$(echo "$current_json" | jq '(.properties.routes // []) | length')

# --- 存兩份檔案: <ts>-before.json (現狀) + <ts>-after.json (本次目標) -----------
BACKUP_DIR="${BACKUP_DIR:-./pe-routes-backups}"
mkdir -p "$BACKUP_DIR"
ts=$(date +%Y%m%dT%H%M%S)

before_file="$BACKUP_DIR/${RT_NAME}-${ts}-before.json"
after_file="$BACKUP_DIR/${RT_NAME}-${ts}-after.json"
latest_before="$BACKUP_DIR/${RT_NAME}-latest-before.json"
latest_after="$BACKUP_DIR/${RT_NAME}-latest-after.json"

printf '%s' "$current_json" > "$before_file"

# latest-before 只在非 restore 模式更新,讓它一直指向「最近一次變更前」的快照
if [[ "$APPLY" != "2" ]]; then
  cp -f "$before_file" "$latest_before"
fi

# 共用的暫存目錄 (jq 大參數走檔案 + PUT body),避免 ARG_MAX 限制。
# 注意:刻意放在 CWD 底下,因為腳本有 MSYS2_ARG_CONV_EXCL='*',
# /tmp/... 這種 POSIX 路徑傳給原生 jq.exe 會解析失敗。
work_dir=$(mktemp -d -p . .work.XXXXXX)
trap 'rm -rf "$work_dir"' EXIT

# --- 計算 target_json (本次 PUT 上去的目標完整內容) ----------------------------
to_create=0
to_update=0
existing_managed_unchanged=0

if [[ "$APPLY" == "2" ]]; then
  # Restore mode: target = 之前的 before snapshot
  source_file="${BACKUP_FILE:-$latest_before}"
  if [[ ! -f "$source_file" ]]; then
    echo "ERROR: 找不到要還原的備份: $source_file"
    echo "       提示: 必須先執行過 APPLY=0/1 才會產生 latest-before.json"
    echo "             或設定 BACKUP_FILE=<備份檔的絕對路徑>"
    exit 1
  fi
  target_json=$(cat "$source_file")
  echo "==> 還原來源: $source_file"
else
  # Add/update mode: target = current_json,但 .properties.routes 改成 (保留非管理 + 加入 desired)
  desired_json=$(printf '%s\n' "${PE_IP_ARR[@]}" \
    | jq -R --arg prefix "$ROUTE_PREFIX" --arg nva "$NVA_IP" '
        select(length > 0) |
        {
          name: ($prefix + (gsub("\\."; "-"))),
          properties: {
            addressPrefix: (. + "/32"),
            nextHopType: "VirtualAppliance",
            nextHopIpAddress: $nva
          }
        }
      ' \
    | jq -s '.')
  desired_names_json=$(echo "$desired_json" | jq -c '[.[].name]')

  # 把 desired / names 寫成檔案,避免 jq --argjson 撞到 ARG_MAX (489 條會爆)
  desired_tmp="$work_dir/desired.json"
  names_tmp="$work_dir/names.json"
  printf '%s' "$desired_json"       > "$desired_tmp"
  printf '%s' "$desired_names_json" > "$names_tmp"

  target_json=$(echo "$current_json" \
    | jq --slurpfile desired "$desired_tmp" --slurpfile names "$names_tmp" '
        .properties.routes = (
          [(.properties.routes // [])[] | select(.name as $n | $names[0] | index($n) | not)]
          + $desired[0]
        )
      ')

  # plan 統計
  existing_managed=$(echo "$current_json" \
    | jq --slurpfile names "$names_tmp" \
         '[(.properties.routes // [])[] | select(.name as $n | $names[0] | index($n))] | length')
  existing_managed_unchanged=$(echo "$current_json" \
    | jq --slurpfile desired "$desired_tmp" '
        [ (.properties.routes // [])[] as $cur
          | $desired[0][]
          | select(.name == $cur.name
                   and .properties.addressPrefix == $cur.properties.addressPrefix
                   and .properties.nextHopType   == $cur.properties.nextHopType
                   and (.properties.nextHopIpAddress // "") == ($cur.properties.nextHopIpAddress // ""))
        ] | length
      ')
  to_create=$(( ${#PE_IP_ARR[@]} - existing_managed ))
  to_update=$(( existing_managed - existing_managed_unchanged ))
fi

# 儲存 after snapshot
printf '%s' "$target_json" > "$after_file"
if [[ "$APPLY" != "2" ]]; then
  cp -f "$after_file" "$latest_after"
fi

after_count=$(echo "$target_json" | jq '(.properties.routes // []) | length')

# --- Plan ---------------------------------------------------------------------
echo ""
echo "----- Plan -----"
echo "Before total routes:        $before_count"
echo "After  total routes:        $after_count"
if [[ "$APPLY" != "2" ]]; then
  echo "  PE-managed (本次):        ${#PE_IP_ARR[@]}"
  echo "    新增 (new):             $to_create"
  echo "    既有需更新 (update):    $to_update"
  echo "    既有已正確 (no-op):     $existing_managed_unchanged"
  echo "  其它 routes 保留:         $(( before_count - (${#PE_IP_ARR[@]} - to_create) ))"
fi
echo ""
echo "  before snapshot: $before_file"
echo "  after  snapshot: $after_file"
echo ""

if [[ "$APPLY" != "2" && $to_create -eq 0 && $to_update -eq 0 ]]; then
  echo "Nothing to change. Done."
  exit 0
fi

if [[ $after_count -gt 400 ]]; then
  echo "WARN: 合併後共 $after_count 條路由,單張 Route Table 預設上限 400 (可開 case 提到 1000)。"
  echo ""
fi

if [[ "$APPLY" == "0" ]]; then
  echo "DRY-RUN. 兩份檔案已存到 $BACKUP_DIR/。要套用請執行:"
  echo "  APPLY=1 NVA_IP=$NVA_IP ROUTE_TABLE_ID=$ROUTE_TABLE_ID ./add-pe-routes.sh"
  echo ""
  echo "套用後若要還原:"
  echo "  APPLY=2 ROUTE_TABLE_ID=$ROUTE_TABLE_ID ./add-pe-routes.sh"
  exit 0
fi

# --- 一次 PUT (APPLY=1 套用 / APPLY=2 還原) ------------------------------------
# 建構 PUT body:從 target_json 拿 location / tags / properties,
# 去除頂層 read-only (provisioningState / resourceGuid / subnets / etag),
# 並把每筆 route 也整理乾淨 (只留 name + properties,移除 etag/provisioningState/id/type)
body_json=$(echo "$target_json" | jq '
  {
    location: .location,
    tags: (.tags // {}),
    properties: {
      disableBgpRoutePropagation: (.properties.disableBgpRoutePropagation // false),
      routes: [
        (.properties.routes // [])[] | {
          name: .name,
          properties: (.properties | del(.provisioningState, .etag))
        }
      ]
    }
  }
')

tmp_body="$work_dir/body.json"
printf '%s' "$body_json" > "$tmp_body"

action_label="Applying"
[[ "$APPLY" == "2" ]] && action_label="Restoring"

echo "$action_label single PUT to '$RT_NAME' (api-version=$api_ver) ..."
if az rest --method PUT \
     --url "https://management.azure.com${ROUTE_TABLE_ID}?api-version=${api_ver}" \
     --body "@$tmp_body" \
     --subscription "$RT_SUB" \
     -o none; then
  echo "Done. Route table '$RT_NAME' 現在共 $after_count 條 routes。"
  echo "  before: $before_file"
  echo "  after:  $after_file"
  if [[ "$APPLY" == "1" ]]; then
    echo ""
    echo "如要還原: APPLY=2 ROUTE_TABLE_ID=$ROUTE_TABLE_ID ./add-pe-routes.sh"
  fi
else
  echo "ERROR: PUT 失敗。body 留在 $tmp_body 供 debug。"
  trap - EXIT  # 失敗時保留 work_dir 供 debug
  exit 1
fi
