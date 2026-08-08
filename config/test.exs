import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :crawlview, CrawlviewWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "OHO/npxhorvOlCmPq443Z5trxPVOZToUFDI3/R+F0DpEAN5RCBo1gsCKCPlX6pAb",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# The suite starts far more than a handful of crawls and does not want to be rationed
# while doing it. The limits themselves are tested by setting them explicitly.
config :crawlview, :max_concurrent_crawls, 200
config :crawlview, :client_crawl_limit, 1_000
