# add-pe-routes.sh

在指定的 Azure **Route Table** 上，為每一個 Private Endpoint (PE) 私網 IP 建立一條 `/32` 的 UDR，next hop 統一指到指定的 Network Virtual Appliance (NVA)。
一次 `PUT` 整張 route table（不再逐筆 `az network route-table route create`），並自動產生 before / after JSON 快照，支援 dry-run、套用、與 rollback。

---

## 適用情境

Spoke VNet 的 PE subnet 已經把 `privateEndpointNetworkPolicies` 設成 `RouteTableEnabled` / `Enabled`，但 NVA 上聯 LAN NIC 所掛的 route table 還沒有指向 PE 的 `/32` 路由，所以 NVA 回傳給 PE 的封包會走錯路（例如跑去 `0.0.0.0/0` → AzFW）。
這支腳本一次把所有 PE 的 `/32` 加進指定 route table，next hop 設成 `VirtualAppliance` → NVA。

---

## 需求

- **bash 4+**（Windows 上請用 **Git Bash**；WSL / Linux / macOS 也可）
- **Azure CLI**（`az`），且已經 `az login`
- **jq**

執行帳號需要對目標 route table 的 **Microsoft.Network/routeTables/write** 權限（例如 `Network Contributor`）。

---

## 檔案結構

把腳本與 IP 清單放在同一個資料夾即可重複使用：

```
<your-folder>/
├─ add-pe-routes.sh       # 主腳本
├─ pe ip.txt              # 預設 PE IP 清單 (可含 header / 註解 / 空行)
└─ pe-routes-backups/     # 第一次執行後自動建立,放 before/after 快照
```

`pe ip.txt` 範例：

```
PrivateIP
10.200.1.4
10.200.1.5
10.200.1.6
# 註解和空行會被自動忽略
10.200.1.7
```

腳本只挑「整行就是一個合法 IPv4」的行，header (`PrivateIP`) / 註解 / 空白行都會自動略過。

---

## 環境變數

| 變數 | 必填 | 說明 |
| --- | --- | --- |
| `ROUTE_TABLE_ID` | ✅ | 目標 route table 的完整 resource ID：`/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/routeTables/<name>` |
| `NVA_IP` | ✅ (APPLY=2 不需要) | Virtual Appliance 的 IP，作為所有 `/32` 的 next hop |
| `PE_IPS` | ⛔ | 一或多個 PE IP，空白或逗號分隔。**最高優先序** |
| `PE_IPS_FILE` | ⛔ | 指向一份每行一個 IP 的檔案。次優先序 |
| `APPLY` | ⛔ | `0`（預設）= dry-run；`1` = 套用變更（自動先備份）；`2` = 從備份還原 (rollback) |
| `ROUTE_PREFIX` | ⛔ | 路由名稱前綴，預設 `pe-`。實際名稱 = `<prefix><ip-with-dashes>`，例如 `pe-10-200-1-4` |
| `BACKUP_DIR` | ⛔ | 備份目錄，預設 `./pe-routes-backups` |
| `BACKUP_FILE` | ⛔ | `APPLY=2` 還原時要還原成的備份檔絕對路徑，預設 `latest-before.json` |

未提供 `PE_IPS` / `PE_IPS_FILE` 時，會自動讀取**腳本所在目錄**底下的 `pe ip.txt`。

---

## 使用方式

### 1. Dry-run（預設）

只讀現狀、計算 plan、把 before/after 兩份 JSON 存到 `./pe-routes-backups/`，不會動 Azure 上的資源：

```bash
NVA_IP=10.20.0.4 ROUTE_TABLE_ID=/subscriptions/<sub>/resourceGroups/rg-hub/providers/Microsoft.Network/routeTables/rt-nva-lan ./add-pe-routes.sh
```

輸出範例：

```
INFO: 讀取 PE IP 清單: /c/.../pe ip.txt
==> Target route table: rt-spoke (rg=rg-privateendpoint, sub=...)
==> Next hop (NVA):     10.20.0.4
==> PE IPs to manage:   489 個

----- Plan -----
Before total routes:        136
After  total routes:        493
  PE-managed (本次):        489
    新增 (new):             357
    既有需更新 (update):    0
    既有已正確 (no-op):     132
  其它 routes 保留:         4

  before snapshot: ./pe-routes-backups/rt-spoke-20260611T143836-before.json
  after  snapshot: ./pe-routes-backups/rt-spoke-20260611T143836-after.json
```

### 2. 套用變更

```bash
APPLY=1 NVA_IP=10.20.0.4 ROUTE_TABLE_ID=/subscriptions/<sub>/resourceGroups/rg-hub/providers/Microsoft.Network/routeTables/rt-nva-lan ./add-pe-routes.sh
```

執行前會自動把現狀存到 `./pe-routes-backups/<rt-name>-<ts>-before.json` 與 `latest-before.json`，再做一次 `PUT`。

### 3. 還原 (rollback)

還原成最近一次「套用前」的狀態：

```bash
APPLY=2 ROUTE_TABLE_ID=/subscriptions/<sub>/resourceGroups/rg-hub/providers/Microsoft.Network/routeTables/rt-nva-lan ./add-pe-routes.sh
```

或還原成指定快照：

```bash
APPLY=2 BACKUP_FILE=./pe-routes-backups/rt-nva-lan-20260611T143000-before.json ROUTE_TABLE_ID=... ./add-pe-routes.sh
```

### 4. 自帶 IP 清單

蓋掉檔案預設、直接從環境變數丟進去：

```bash
PE_IPS="10.0.92.4 10.0.93.132" NVA_IP=10.20.0.4 ROUTE_TABLE_ID=... ./add-pe-routes.sh
```

或指向別的檔案：

```bash
PE_IPS_FILE=./other-case-ips.txt NVA_IP=10.20.0.4 ROUTE_TABLE_ID=... ./add-pe-routes.sh
```

---

## 行為與保證

- **只用一次 `PUT`** 把整張 route table 寫回去（透過 `az rest --method PUT`），效能不會被 route 數量拖垮。
- **抓現狀走 `az rest GET`** 取原生 ARM JSON。**不要**用 `az network route-table show`──它會把 `routes` / `disableBgpRoutePropagation` flatten 到頂層，後面 jq 抓不到 `.properties.routes`。
- **路由命名**：每條路由名稱固定為 `<ROUTE_PREFIX><ip-with-dashes>`，例如 `pe-10-200-1-4`。
- **Merge 邏輯**：
  - 名稱與本次 `PE_IPS` 對應的舊 route → 覆寫成新內容
  - 其它所有 routes（含名稱不衝突的舊 `pe-*`、預設 `0.0.0.0/0` 等）→ 完整保留
- **PUT body 整理**：移除 read-only 欄位（`provisioningState`、`etag`、`subnets`、`resourceGuid`），避免 ARM 拒收。
- **備份**：每次 run 都會產生
  - `<rt>-<ts>-before.json` — 變更前完整 route table
  - `<rt>-<ts>-after.json`  — 此次要 `PUT` 上去的完整內容
  - `<rt>-latest-before.json` / `<rt>-latest-after.json` — 最近一次的指標（`APPLY=2` 不更新）

---

## 限制

- 單張 Route Table 預設最多 **400** 條路由，可開 support case 提升至 **1000**：
  <https://learn.microsoft.com/azure/azure-resource-manager/management/azure-subscription-service-limits#networking-limits>
- 計算量是「該 RT 上**所有路由**總和」，包含原本不是 PE 的路由。
- 留意「肥型 PE」（例如一個 AMPLS 就佔 ~11 條 `/32`），要事先把它們算進總額。
- 合併後超過 400 條時，腳本會印 `WARN`，但**不會**阻止 `PUT`；超過硬上限 (1000) 才會被 ARM 拒收。

---

## 疑難排解

### `jq: Could not open ... /tmp/...: No such file or directory`

腳本刻意設了 `MSYS2_ARG_CONV_EXCL='*'`（為了不讓 Git Bash 把 Azure resource ID 裡面的 `/` 開頭路徑亂轉），副作用是 `/tmp/...` 這種 POSIX 路徑傳給原生 `jq.exe` 也不會被轉成 Windows 路徑。
**已處理**：腳本把工作暫存目錄改放在 `./` 底下（`mktemp -d -p . .work.XXXXXX`），路徑是相對的，bash 與 jq.exe 看到的位置一致。如果你自己再改路徑相關邏輯，記得避開絕對 POSIX 路徑。

### `Argument list too long`

舊版本用 `jq --argjson` 把所有 routes 當命令列參數傳，IP 數量一多就會撞到 `ARG_MAX`。
**已處理**：改用 `jq --slurpfile` 從暫存檔讀 `desired.json` / `names.json`。

### `ERROR: 找不到 PE IP 清單檔: <script_dir>/pe ip.txt`

把 `pe ip.txt` 跟腳本放同一資料夾，或用 `PE_IPS_FILE=...` 指到其它路徑，或直接用 `PE_IPS="10.0.0.1 10.0.0.2"`。

### `ERROR: ROUTE_TABLE_ID 格式不正確`

完整 resource ID 必須長這樣：

```
/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/routeTables/<name>
```

可以從 Portal 的 route table → Properties → **Resource ID** 直接複製。

### Route Table 上有 1000 條，但 PUT 失敗 / 太慢

ARM 對單一 route table 的 PUT 還是有大小與時間限制；超大張的 RT 建議拆成多張，或事先確認 quota 已升到 1000。

---

## 在不同 case 重複使用

把整個資料夾（`add-pe-routes.sh` + `pe ip.txt`）複製到新地方，把新的 IP 清單覆蓋掉 `pe ip.txt` 即可。`pe-routes-backups/` 會在新位置重新生成，不會污染上一個 case 的快照。
