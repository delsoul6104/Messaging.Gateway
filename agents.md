# Messaging.Gateway — Agent Guide

## Architecture Overview

This project is a **message gateway** built with **.NET 10** following **Clean Architecture** principles. It exposes a single Minimal API endpoint that accepts a message payload and publishes it to a backend messaging system (NATS JetStream or Redis Streams) based on configuration-driven routing.

```
┌─────────────────────────────────────────────────────┐
│              Messaging.Gateway.Api (Presentation)    │
│  ┌──────────────────────────────────────────────┐   │
│  │  Minimal API: MessagingEndpoints             │   │
│  │  Filters: FluentValidationFilter<T>          │   │
│  │  Middleware: ApiTokenHeaderMiddleware        │   │
│  │  Handlers: GlobalExceptionHandler            │   │
│  └──────┬───────────────────────────────────────┘   │
└─────────┼───────────────────────────────────────────┘
          │
┌─────────┼───────────────────────────────────────────┐
│         │  Messaging.Gateway.Application            │
│  ┌──────┴──────────────────────────────────────┐    │
│  │  Features (vertical slices)                 │    │
│  │  • PublishMessageHandler                    │    │
│  │  Abstractions                               │    │
│  │  • IMessagePublisher                        │    │
│  │  • IMessageRouteResolver + MessagePublishRoute   │
│  │  Contracts                                  │    │
│  │  • PublishMessageRequest / PublishMessageResult  │
│  └──────┬──────────────────────────────────────┘    │
└─────────┼───────────────────────────────────────────┘
          │
┌─────────┼───────────────────────────────────────────┐
│         │  Messaging.Gateway.Infrastructure         │
│  ┌──────┴──────────────────────────────────────┐    │
│  │  Routing: MessageRouteResolver              │    │
│  │  Publishers:                                │    │
│  │  • NatsMessagePublisher      ──► NATS JS    │    │
│  │  • RedisStreamMessagePublisher ─► Redis     │    │
│  │  Options / Logging / Http resilience        │    │
│  └─────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────┘
```

External sibling repos (referenced by relative path in `Messaging.Gateway.Api.slnx`, must sit next to this repo):
- `../Common` — shared abstractions/contracts/cache/infrastructure
- `../Common.Redis` — `AddCommonRedis`, `IRedisDatabaseProvider` used by the Redis publisher

## Project Structure

```
Messaging.Gateway/
├── src/
│   ├── Messaging.Gateway.Api/             # Presentation layer (Minimal API, no controllers)
│   │   ├── DependencyInjection/           # AddConfiguration, AddPresentation, UsePipeline, MapApiEndpoints
│   │   ├── Endpoints/Messaging/           # MessagingEndpoints (POST /api/Messaging/PublishMessage)
│   │   ├── Filters/                       # FluentValidationFilter<T> (Minimal API endpoint filter)
│   │   ├── Handlers/                      # GlobalExceptionHandler (IExceptionHandler)
│   │   ├── Middleware/                    # ApiTokenHeaderMiddleware (protects /api)
│   │   ├── Models/Validation/             # ValidationErrorPayload
│   │   ├── Services/                      # RequestContext (IRequestContext impl)
│   │   ├── Startup/                       # Log path resolution + bootstrap logger
│   │   ├── Validators/Messaging/          # PublishMessageRequestValidator (FluentValidation)
│   │   └── Program.cs                     # Entry point
│   ├── Messaging.Gateway.Application/     # Use cases & abstractions
│   │   ├── Abstractions/                  # IMessagePublisher, IMessageRouteResolver, MessagePublishRoute, MessagingPublishMode
│   │   ├── Contracts/Messaging/           # PublishMessageRequest, PublishMessageResult, ProviderPublishResult
│   │   ├── DependencyInjection/           # AddApplication (registers feature handlers)
│   │   ├── Features/Messaging/PublishMessage/  # PublishMessageHandler (vertical slice)
│   │   └── Mappings/                      # Riok.Mapperly profiles (placeholder)
│   └── Messaging.Gateway.Infrastructure/  # Implementation layer
│       ├── Configuration/                 # Redis/SignalR/Db configuration read extensions
│       ├── DependencyInjection/           # AddOptions, AddInfrastructure, AddMessagingGateway
│       ├── Http/                          # HttpResilienceConfigurations (non-dev only)
│       ├── Logging/                       # Serilog extensions, PropertyFilterEnricher, CustomJsonFormatter
│       ├── Options/                       # MessagingPublishSettings (+ RouteOptions), NatsOptions
│       ├── Publishers/                    # NatsMessagePublisher, RedisStreamMessagePublisher
│       ├── Routing/                       # MessageRouteResolver (template + legacy route logic)
│       └── Startup/                       # StartupContext record (AppPath/LogPath/Hospital/Environment/IsDevelopment)
├── deploy/                                # Messaging_Gateway_Api_Publish.ps1 (publish + 7z packaging)
├── Directory.Packages.props               # Central package management (CPM)
└── Messaging.Gateway.Api.slnx             # Solution (includes ../Common and ../Common.Redis projects)
```

## Key Components

### 1. MessagingEndpoints (`Api/Endpoints/Messaging/MessagingEndpoints.cs`)

Minimal API, mounted under the `/api` route group by `MapApiEndpoints()`:

```csharp
group.MapPost("/PublishMessage", PublishMessageAsync)
    .AddEndpointFilter<FluentValidationFilter<PublishMessageRequest>>();
```

- Delegates to `PublishMessageHandler.HandleAsync()`
- Returns `Ok<MessageGatewayResponse>`; `MessageGatewayResponse` (Common.Contracts) contains only `MessageId` = provider message id (NATS sequence / Redis stream entry id). **No VueApiResponse wrapper on success.**

### 2. PublishMessageHandler (`Application/Features/Messaging/PublishMessage/`)

Vertical-slice handler, registered scoped in `AddApplication()`:

1. Resolve route via `IMessageRouteResolver.Resolve(streamKey)`
2. Generate `messageId = Guid.NewGuid().ToString("N")` (use-case concern, not the publisher's)
3. Call `IMessagePublisher.PublishAsync(route, messageId, request.Data.GetRawText(), ct)`
4. Compose `PublishMessageResult` from `ProviderPublishResult`

### 3. IMessagePublisher (`Application/Abstractions/IMessagePublisher.cs`)

```csharp
public interface IMessagePublisher
{
    Task<ProviderPublishResult> PublishAsync(
        MessagePublishRoute route, string messageId, string payload, CancellationToken ct = default);
}
```

Publishers only transport an already-resolved route; they do NOT resolve routes or generate message ids.

- **NatsMessagePublisher** — `NatsConnection` + `NatsJSContext` (JetStream), publishes UTF-8 bytes with `Nats-Msg-Id` header, returns `ack.Seq` as provider message id. Singleton, implements `IAsyncDisposable`. Auth precedence: `Token` → `User`/`Password` → none.
- **RedisStreamMessagePublisher** — `IRedisDatabaseProvider` (Common.Redis), `StreamAddAsync` with `messageId` + `payload` entries, returns the stream entry id.

### 4. IMessageRouteResolver / MessageRouteResolver (`Infrastructure/Routing/`)

Resolution flow:
1. Normalize `streamKey` (trim + lowercase)
2. Match `MessagingPublishSettings.Routes` via `IOptionsMonitor` (hot-reload; editing routes in appsettings takes effect without restart)
3. Apply template with `{Hospital}`, `{Env}`, `{StreamKey}` placeholders (see Route Template Values)
4. Destination determined by `PublishMode` **captured at startup** (publisher DI registration is fixed at startup; changing `PublishMode` requires a restart)

Error behavior: unknown streamKey → `BusinessException` error code `4004` / HTTP 400 (caller input error); missing `MessagingPublish:Routes` config → `InvalidOperationException` (500).

### 5. Request pipeline (`Api/DependencyInjection/ApplicationBuilderExtensions.UsePipeline`)

Order: `UseRouting` → Swagger (Development only) → `UseCors("AllowAll")` → `UseStatusCodePages` (400/415 on `/api` rewritten to `VueApiResponse` error `4000`) → `UseExceptionHandler` → `UseApiTokenMiddleware` → `MapApiEndpoints`.

- `ApiTokenHeaderMiddleware` protects only `/api`; excluded paths: `/swagger`, `/hubs`, `/api/Captcha`, `/api/SignalR`, `/api/electron`, `/api/health`. No token configured → validation disabled.
- `GlobalExceptionHandler` maps: `OperationCanceledException` (client abort) → swallowed; `BadHttpRequestException` → status + `4000`; `BusinessException` → its `ErrorCode`/`StatusCode`; else → `5999` / 500. All use `VueApiResponse<object>` error shape.
- `FluentValidationFilter<T>` returns HTTP 400 (not 200 + 4000) because Gateway callers check status codes; body is still `VueApiResponse<ValidationErrorPayload>`.

### 6. DI registration order (`Program.cs`)

```
builder.Services
    .AddOptions(cfg, startup)          # bind AppSettings / MessagingPublishSettings / NatsOptions (+ value singletons)
    .AddInfrastructure(cfg, startup)   # AddHttpClients + AddMessagingGateway (publisher per PublishMode)
    .AddPresentation()                 # HttpContextAccessor, RequestContext, FluentValidation, Swagger, CORS, exception handler
    .AddApplication();                 # feature handlers
```

Configuration files loaded by `AddConfiguration` (later overrides earlier): `appsettings.json` → `appsettings.{Hospital}.json` → `appsettings.HIS.{Hospital}.json` → `appsettings.{Hospital}.{Environment}.json` → `appsettings.HIS.{Hospital}.{Environment}.json` → environment variables. `Hospital` / `ASPNETCORE_ENVIRONMENT` are read from **appsettings values** (not the process environment), falling back to `builder.Environment.EnvironmentName`.

## Message Publishing Flow

```
Client                    Api Endpoints          Application                Infrastructure
  │  POST /api/Messaging/     │                      │                          │
  │  PublishMessage           │                      │                          │
  │  {streamKey, data}        │                      │                          │
  │──────────────────────────►│  FluentValidationFilter validates request       │
  │                           │  HandleAsync(request) │                          │
  │                           │─────────────────────►│  Resolve(streamKey)      │
  │                           │                      │─────────────────────────►│
  │                           │                      │   MessagePublishRoute    │
  │                           │                      │  PublishAsync(route,     │
  │                           │                      │    messageId, payload)   │
  │                           │                      │─────────────────────────►│
  │                           │                      │                          │──► NATS JetStream / Redis Stream
  │                           │                      │   ProviderPublishResult  │
  │                           │  PublishMessageResult│                          │
  │  200 { "messageId": ... } │◄─────────────────────┴──────────────────────────┤
  │◄──────────────────────────│                                                 │
```

## Route Template Values

`{StreamKey}` is always the lowercased stream key.

**Regular routes** (every route except the legacy ones below): `{Hospital}` and `{Env}` are the raw `Hospital` and `ASPNETCORE_ENVIRONMENT` values from appsettings (trimmed only, no case conversion or alias mapping). Add new routes this way; no code change is needed.

**Legacy routes** (hardcoded in `MessageRouteResolver` because downstream consumers depend on the existing names):

| Route keys | NATS subject | Redis stream |
|------------|--------------|--------------|
| `prepare_sign`, `complete_sign` | hospital lowercase, normalized env | hospital lowercase, env `dev` / `prod` |
| `prepare_release_doc`, `complete_release_doc` | hospital lowercase, normalized env | hospital uppercase, env `Development` / `Production` |

Environment normalization (legacy routes only):

| Input | Normalized |
|-------|-----------|
| `production`, `prod` | `production` |
| `staging`, `stage` | `staging` |
| `development`, `develop`, `dev` | `development` |
| `test`, `testing` | `test` |
| anything else | lowercased, passed through |

## Redis Configuration

Bound via `AddCommonRedis` (Common.Redis) using the environment name from `StartupContext`. Connection string fallback: `Redis:{Env}:Configuration` → `Redis:{Env}:Cache:Configuration` → `Redis:{Env}:SignalR:Configuration`. The `IRedisDatabaseProvider` resolves the default database for stream publishing.

## Development Guidelines

### Adding a new publisher

1. Create a class in `Infrastructure/Publishers/` implementing `IMessagePublisher`
2. Add the corresponding mode to the `MessagingPublishMode` enum (in `Application/Abstractions/IMessageRouteResolver.cs`) if needed
3. Register the new publisher in `InfrastructureServiceCollectionExtensions.AddMessagingGateway()` with conditional DI based on `PublishMode`
4. Handle the new mode in `MessageRouteResolver.Resolve()`'s `Destination` switch

### Adding a new endpoint (vertical slice)

1. Minimal API endpoint in `Api/Endpoints/{Feature}/`, mounted under the `/api` group in `MapApiEndpoints()`
2. Handler in `Application/Features/{Feature}/{UseCase}/`, registered in `AddApplication()`
3. If validation needed: `AbstractValidator<T>` in `Api/Validators/{Feature}/` (auto-registered via `AddValidatorsFromAssemblyContaining<Program>()`) plus `.AddEndpointFilter<FluentValidationFilter<T>>()` on the endpoint
4. New routes are config-only (hot-reload) unless downstream consumers depend on legacy naming

### Code conventions

- **File-scoped namespaces** (`namespace X.Y;`)
- **Primary constructors** where appropriate
- **`sealed` classes** unless inheritance is required
- **Records** for DTOs/contracts, with the **`required` modifier** on properties
- **Vertical slices**: one folder per feature under `Application/Features/{Feature}/{UseCase}/`
- Central package version management via `Directory.Packages.props` (no versions in csproj)
- Target framework: `net10.0`; `<Nullable>enable</Nullable>`; `<ImplicitUsings>enable</ImplicitUsings>`
- XML doc comments + inline comments are written in Traditional Chinese (zh-TW)

### Testing

No test projects exist yet. When writing tests:
- Test `MessageRouteResolver` with regular vs legacy stream keys, templates, and environment normalization
- Test each publisher with a mocked `IMessageRouteResolver` and connection objects
- Test `PublishMessageHandler` with mocked resolver + publisher
- Test `FluentValidationFilter` and `GlobalExceptionHandler` mappings (4000 / 4004 / 5999)