# These catch-all clauses preserve the modules' headline totality contracts even
# though Dialyzer proves them unreachable under dependencies' current return types.
# They must remain defensive if a dependency's declared return type later widens.
[
  # Fetcher.normalize_request_result/3 final totality clause.
  ~r|lib/crawlview/fetcher\.ex:\d+(?::\d+)?:pattern_match_cov .*<__unexpected@|,
  # Url.valid_port?/1 final totality clause.
  ~r|lib/crawlview/url\.ex:\d+(?::\d+)?:pattern_match_cov .*__port@|,
  # Url.encoded_component?/1 final totality clause.
  ~r|lib/crawlview/url\.ex:\d+(?::\d+)?:pattern_match_cov .*__component@|,
  # CrawlLive.error_sentence/1 fallback for future URL rejection atoms.
  ~r|lib/crawlview_web/live/crawl_live\.ex:\d+(?::\d+)?:pattern_match_cov .*_reason@|
]
