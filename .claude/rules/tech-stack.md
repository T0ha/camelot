# Technology Stack

| Layer | Library |
|-------|---------|
| Data | Ash |
| Database | Ecto + AshPostgres + PostgreSQL |
| Web | AshPhoenix |
| Caching | Nebulex |
| Background jobs | AshOban |
| HTTP client | Req |
| JSON | Jason |
| Observability | OpenTelemetry |
| Metrics | Telemetry |
| Testing | ExUnit |
| Test coverage | Excoveralls |
| AI tooling | Tidewave (MCP dev server), AshAI |
| Linting | Credo, Styler |
| Static analysis | Dialyxir |
| Dep usage checks | usage_rules |

### Prohibited Libraries

- HTTPoison, Tesla, Mint — use Req
- Poison — use Jason
- Cachex — use Nebulex

---
