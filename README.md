# Messaging.Gateway

統一的訊息發布網關服務，提供標準化 API 將訊息發布至 NATS JetStream 或 Redis Streams，並依設定驅動的路由決定目的地。

## 架構概覽

```
┌─────────────────────────────────────────────────────┐
│                    Client / App                      │
└─────────────────────┬───────────────────────────────┘
                      │ POST /api/Messaging/PublishMessage
                      │ Header: apiToken
                      ▼
┌─────────────────────────────────────────────────────┐
│              Messaging.Gateway.Api                   │
│  ┌──────────────────────────────────────────────┐   │
│  │  ApiTokenHeaderMiddleware（apiToken 驗證）     │   │
│  │  MessagingEndpoints (Minimal API)             │   │
│  │  FluentValidationFilter (FluentValidation)    │   │
│  │  GlobalExceptionHandler (統一例外回應)         │   │
│  └──────────────────┬───────────────────────────┘   │
└─────────────────────┼───────────────────────────────┘
                      │
┌─────────────────────┼───────────────────────────────┐
│         Messaging.Gateway.Application               │
│  ┌──────────────────┴───────────────────────────┐   │
│  │  Features                                     │   │
│  │  • PublishMessageHandler（route 解析 + 發布）   │   │
│  │  Abstractions                                 │   │
│  │  • IMessagePublisher                          │   │
│  │  • IMessageRouteResolver / MessagePublishRoute│   │
│  │  Contracts                                    │   │
│  │  • PublishMessageRequest / PublishMessageResult│  │
│  └──────────────────┬───────────────────────────┘   │
└─────────────────────┼───────────────────────────────┘
                      │
┌─────────────────────┼───────────────────────────────┐
│       Messaging.Gateway.Infrastructure              │
│  ┌──────────────────┴───────────────────────────┐   │
│  │  Routing                                      │   │
│  │  • MessageRouteResolver（模板路由解析）          │   │
│  │  Publishers                                   │   │
│  │  • NatsMessagePublisher     ──► NATS JetStream │  │
│  │  • RedisStreamMessagePublisher ─► Redis Stream │  │
│  │  Options                                      │   │
│  │  • MessagingPublishSettings / NatsOptions     │   │
│  └──────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

## 功能特色

- **統一 API**：單一 `POST /api/Messaging/PublishMessage` 端點，無縫切換後端訊息系統
- **雙發布模式**：支援 NATS JetStream 與 Redis Streams，由 `PublishMode` 於啟動時決定
- **設定驅動路由**：路由模板支援 `{Hospital}`、`{Env}`、`{StreamKey}` 變數替換；路由修改不需重啟即可生效
- **API Token 保護**：`/api` 下的端點需攜帶 `apiToken` header
- **FluentValidation 驗證**：以 Minimal API Endpoint Filter 套用請求驗證
- **統一回應與例外處理**：`GlobalExceptionHandler` + `UseStatusCodePages` 統一輸出錯誤格式
- **Serilog 結構化日誌**：輸出至主控台與滾動檔案

## 環境需求

- [.NET 10.0 SDK](https://dotnet.microsoft.com/download/dotnet/10.0)
- NATS Server（`PublishMode = Nats` 時需要）
- Redis Server（`PublishMode = RedisStream` 時需要）
- **相鄰存放庫**（solution 以相對路徑參考，需與本專案放在同一上層資料夾）：
  - `../Common`（Common.Abstractions / Common.Contracts / Common.Cache / Common.Infrastructure / Common.Shared 等）
  - `../Common.Redis`（Redis 連線與 Database Provider）

## 快速開始

### 還原與建置

```bash
dotnet restore Messaging.Gateway.Api.slnx
dotnet build Messaging.Gateway.Api.slnx
```

### 執行

```bash
cd src\Messaging.Gateway.Api
dotnet run
```

- 本機 launchSettings（`dotnet run`）：`http://localhost:18776`，啟動後開啟 `/swagger`
- appsettings.json 中的 Kestrel 綁定：`http://*:17001`（正式環境）
- Swagger / OpenAPI 僅在 Development 環境啟用

### 呼叫範例

```bash
curl -X POST http://localhost:18776/api/Messaging/PublishMessage \
  -H "Content-Type: application/json" \
  -H "apiToken: <ApiTokenSettings:Token>" \
  -d "{\"streamKey\":\"complete_sign\",\"data\":{\"chartNo\":\"123456\"}}"
```

## 設定說明

設定集中在 `src/Messaging.Gateway.Api/appsettings*.json`，載入順序（後者覆蓋前者）：

1. `appsettings.json`（基底，含 Hospital、MessagingPublish、ApiTokenSettings 等）
2. `appsettings.{Hospital}.json`（院所共用設定，如 `appsettings.SYSCOM.json`）
3. `appsettings.HIS.{Hospital}.json`（選擇性）
4. `appsettings.{Hospital}.{Environment}.json`（院所 × 環境覆蓋）
5. `appsettings.HIS.{Hospital}.{Environment}.json`（選擇性）
6. 環境變數

> 注意：此處的 `ASPNETCORE_ENVIRONMENT` 是讀取 **appsettings 內的設定值**（非環境變數），未設定時才回退 `builder.Environment.EnvironmentName`。

### MessagingPublish 設定

```json
{
  "MessagingPublish": {
    "PublishMode": "RedisStream",
    "MaxPayloadBytes": 10240,
    "Routes": {
      "complete_sign": {
        "NatsSubjectTemplate": "app.{Hospital}.{Env}.sign.complete",
        "RedisStreamTemplate": "{Hospital}_{Env}_complete_sign"
      }
    }
  }
}
```

| 參數 | 說明 | 預設值 |
|------|------|--------|
| `PublishMode` | 發布模式：`Nats` 或 `RedisStream`（相容舊值 `Redis`）。**啟動時固定**，變更需重啟 | `Nats` |
| `MaxPayloadBytes` | 最大承載大小（位元組） | `10240` |
| `Routes` | streamKey → 路由模板對應表；**熱載入**（透過 `IOptionsMonitor`），修改不需重啟 | — |

### 路由模板

| 變數 | 說明 |
|------|------|
| `{Hospital}` | appsettings 的 `Hospital` 原值（僅 trim，不轉大小寫） |
| `{Env}` | appsettings 的 `ASPNETCORE_ENVIRONMENT` 原值（僅 trim，不轉大小寫） |
| `{StreamKey}` | 請求的 streamKey（轉小寫） |

**舊路由（Legacy）**：`prepare_sign`、`complete_sign`、`prepare_release_doc`、`complete_release_doc` 因下游已依賴既有命名，採寫死轉換規則（見 `MessageRouteResolver`）：

| 路由 | NATS subject | Redis stream |
|------|--------------|--------------|
| `prepare_sign`、`complete_sign` | hospital 小寫 + 正規化環境名 | hospital 小寫，環境 `dev` / `prod` |
| `prepare_release_doc`、`complete_release_doc` | hospital 小寫 + 正規化環境名 | hospital 大寫，環境 `Development` / `Production` |

舊路由環境名正規化：`production|prod → production`、`staging|stage → staging`、`development|develop|dev → development`、`test|testing → test`，其餘轉小寫保留。

### Nats 設定

```json
{
  "Nats": {
    "Url": "nats://localhost:4222",
    "User": "",
    "Password": "",
    "Token": "",
    "ClientName": "common-messaging-publisher",
    "ConnectTimeoutSeconds": 10,
    "RequestTimeoutSeconds": 30
  }
}
```

認證優先序：`Token` → `User`/`Password` → 無認證。

### Redis 設定

Redis 設定透過 `Common.Redis` 的 `AddCommonRedis` 綁定，以 appsettings 內的環境名稱取值：

```json
{
  "Redis": {
    "Development": {
      "Configuration": "172.16.82.51:6379,password=xxx,defaultDatabase=1"
    },
    "Production": {
      "Configuration": "..."
    }
  }
}
```

連線字串 fallback 順序：`Redis:{Env}:Configuration` → `Redis:{Env}:Cache:Configuration` → `Redis:{Env}:SignalR:Configuration`。

### ApiToken 設定

```json
{
  "ApiTokenSettings": {
    "Token": "<your-token>"
  }
}
```

`ApiTokenHeaderMiddleware` 只保護 `/api` 前綴；以下路徑排除驗證：`/swagger`、`/hubs`、`/api/Captcha`、`/api/SignalR`、`/api/electron`、`/api/health`。未設定 Token 時不啟用驗證。

## API 文件

### 發布訊息

```
POST /api/Messaging/PublishMessage
Header: apiToken: <token>
```

#### Request Body

```json
{
  "streamKey": "complete_sign",
  "data": {
    "chartNo": "123456",
    "result": "Normal"
  }
}
```

| 欄位 | 型別 | 說明 |
|------|------|------|
| `streamKey` | string (必要) | 串流識別碼，用於路由比對（FluentValidation 驗證非空） |
| `data` | object (必要) | 任意 JSON 格式的訊息內容 |

#### Response (200 OK)

```json
{
  "messageId": "42"
}
```

| 欄位 | 說明 |
|------|------|
| `messageId` | 後端 provider 產生的訊息編號（NATS JetStream sequence / Redis Stream entry id） |

> 成功回應為精簡格式（`MessageGatewayResponse`），僅回傳 provider 訊息編號。

#### 錯誤回應

驗證失敗（400 Bad Request）— body 使用 `VueApiResponse` 格式：

```json
{
  "isSuccess": false,
  "errorCode": "4000",
  "message": "streamKey is required."
}
```

| 情境 | 狀態碼 | 錯誤碼 |
|------|--------|--------|
| FluentValidation 驗證失敗 / Minimal API 繫結失敗 | 400 / 415 | `4000` |
| streamKey 不存在於 Routes 設定 | 400 | `4004` |
| apiToken 驗證失敗 | 401 | —（純文字） |
| 系統錯誤 | 500 | `5999` |

## 專案結構

```
Messaging.Gateway
├── src/
│   ├── Messaging.Gateway.Api            # API 表現層：Minimal API 端點、Middleware、驗證、Swagger
│   │   ├── DependencyInjection/         # AddPresentation / UsePipeline / 端點映射 / 設定載入
│   │   ├── Endpoints/Messaging/         # MessagingEndpoints（Minimal API）
│   │   ├── Filters/                     # FluentValidationFilter<T>
│   │   ├── Handlers/                    # GlobalExceptionHandler
│   │   ├── Middleware/                  # ApiTokenHeaderMiddleware
│   │   ├── Models/Validation/           # ValidationErrorPayload
│   │   ├── Services/                    # RequestContext（IRequestContext 實作）
│   │   ├── Startup/                     # 啟動樣板（log 目錄、bootstrap logger）
│   │   ├── Validators/Messaging/        # PublishMessageRequestValidator
│   │   └── Program.cs                   # 應用程式進入點
│   ├── Messaging.Gateway.Application    # 應用層：Use Case、抽象介面、Contracts
│   │   ├── Abstractions/                # IMessagePublisher、IMessageRouteResolver、MessagePublishRoute
│   │   ├── Contracts/Messaging/         # PublishMessageRequest、PublishMessageResult、ProviderPublishResult
│   │   ├── DependencyInjection/         # AddApplication
│   │   ├── Features/Messaging/PublishMessage/  # PublishMessageHandler（vertical slice）
│   │   └── Mappings/                    # Riok.Mapperly 對應 profile（預留）
│   └── Messaging.Gateway.Infrastructure # 基礎設施層：Routing、Publishers、Options、Logging
│       ├── Configuration/               # 設定讀取擴充（Redis、SignalR、Db 連線）
│       ├── DependencyInjection/         # AddOptions / AddInfrastructure / AddMessagingGateway
│       ├── Http/                        # HTTP resilience 設定
│       ├── Logging/                     # Serilog 擴充、PropertyFilterEnricher、CustomJsonFormatter
│       ├── Options/                     # MessagingPublishSettings、NatsOptions
│       ├── Publishers/                  # NatsMessagePublisher、RedisStreamMessagePublisher
│       ├── Routing/                     # MessageRouteResolver
│       └── Startup/                     # StartupContext（AppPath/LogPath/Hospital/Environment）
├── deploy/                              # 部署腳本
│   └── Messaging_Gateway_Api_Publish.ps1
├── db_schema/                           # 資料庫 Schema（目前為空）
├── Directory.Packages.props             # 中央套件版本管理（CPM）
└── Messaging.Gateway.Api.slnx           # Solution（含 ../Common 與 ../Common.Redis 專案）
```

## 部署

使用部署 PowerShell 腳本（會先重建 Common 後發布、壓縮為 7z）：

```powershell
.\deploy\Messaging_Gateway_Api_Publish.ps1
```

- 產物輸出至 `D:\deploy\Messaging_Gateway_Deploy\Backend`，檔名 `Messaging_Gateway_Backend_{version}.7z`
- 版本取自 csproj 的 `<AssemblyVersion>`（目前 `1.0.1`）
- 專案內含 `web.config`（上傳上限 2GB），可直接部署至 IIS

## 開發

### 新增發布提供者

1. 在 `Infrastructure/Publishers/` 新增實作 `IMessagePublisher` 的類別
2. 在 `MessagePublishMode` 列舉新增對應模式（如需要）
3. 在 `Infrastructure/DependencyInjection/InfrastructureServiceCollectionExtensions.AddMessagingGateway()` 依 `PublishMode` 條件註冊
4. 在 `MessageRouteResolver.Resolve()` 的 `Destination` switch 中處理新模式

### 新增路由

一般路由只需在 appsettings 的 `MessagingPublish:Routes` 新增條目（熱載入），不需修改程式碼。僅下游相依既有命名時，才需要在 `MessageRouteResolver` 加入 legacy 規則。

### 新增 API 端點

1. 在 `Api/Endpoints/{Feature}/` 建立 Minimal API 端點，掛在 `MapApiEndpoints` 的 `/api` group 下
2. 在 `Application/Features/{Feature}/` 建立 vertical slice handler（於 `AddApplication()` 註冊）
3. 需要驗證時在 `Api/Validators/{Feature}/` 建立 `AbstractValidator<T>`（自動註冊），並在端點加上 `.AddEndpointFilter<FluentValidationFilter<T>>()`
