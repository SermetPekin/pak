# Fixing pak / download.file on Windows Corporate Networks

## Background

On corporate Windows machines, HTTPS downloads from R often fail with errors like:

```
Error in download.file(...) : cannot open URL 'https://...'
SSL connect error
```

while the same URL works fine in a browser or via the `curl` R package.
There are two distinct root causes — try them in order.

---

## Step 1 — Identify which problem you have

Open R and run:

```r
# Does curl work at all?
curl::curl_download("https://cran.r-project.org/src/base/NEWS", tmp <- tempfile())
file.info(tmp)$size   # should be > 0

# Does the system know about a proxy?
curl::ie_get_proxy_for_url("https://cran.r-project.org")
```

- If `curl::curl_download` **fails** too → escalate to IT, the network blocks R entirely.
- If `curl::curl_download` **succeeds** but `utils::download.file` fails → continue below.
- If `ie_get_proxy_for_url` returns a proxy address (e.g. `"http://proxy.corp.com:8080"`)
  → you are hitting **Problem 2** (proxy auto-config). Skip directly to Step 3.
- If it returns `""` or `NULL` → you are likely hitting **Problem 1** (MITM SSL). Start at Step 2.

---

## Problem 1 — MITM SSL proxy (Zscaler, BlueCoat, Cisco Umbrella, …)

Corporate proxies intercept HTTPS connections and re-sign them with their own CA
certificate. Windows' TLS library (Schannel) then tries to verify revocation status
for that certificate via CRL/OCSP — but those endpoints are on the internet, behind
the proxy, so the request deadlocks and R reports an SSL error.

### Quick test

```r
Sys.setenv(R_LIBCURL_SSL_REVOKE_BEST_EFFORT = "TRUE")
utils::download.file(
  "https://cran.r-project.org/src/base/NEWS",
  tempfile(),
  quiet = TRUE
)
```

If that succeeds, this is your problem.

### Permanent fix — add to `~/.Renviron`

Open or create the file `C:\Users\<you>\Documents\.Renviron` and add:

```
R_LIBCURL_SSL_REVOKE_BEST_EFFORT=TRUE
```

Find the file path with:

```r
normalizePath("~/.Renviron", mustWork = FALSE)
# or open it directly:
usethis::edit_r_environ()   # if usethis is installed
```

Restart R. From now on `utils::download.file` and `install.packages` will work
without any code changes.

### What this does (and the trade-off)

Setting `R_LIBCURL_SSL_REVOKE_BEST_EFFORT=TRUE` tells Schannel to treat a
revocation check failure as a warning rather than a hard error. This is safe in
practice on a managed corporate network — the proxy's CA cert is already trusted
because IT pushed it into the Windows certificate store. The only theoretical risk
is that a genuinely revoked certificate would not be caught, but that cert would
have to be one your corporate CA re-signed, which is implausible.

---

## Problem 2 — Proxy auto-configuration (PAC / WPAD)

The corporate proxy is configured through Windows Internet Options (a PAC file or
WPAD auto-discovery), not through environment variables. R's built-in `libcurl`
only checks `http_proxy` / `https_proxy` env vars, so it never discovers the proxy
and tries to connect directly — which the network perimeter blocks.

The `curl` R package works because it calls `WinHttpGetProxyForUrl` (the same
Windows API used by Internet Explorer / Edge), which reads PAC/WPAD settings.

### Quick test

```r
proxy <- curl::ie_get_proxy_for_url("https://cran.r-project.org")
cat("Detected proxy:", proxy, "\n")
```

### Temporary fix (current R session only)

```r
proxy <- curl::ie_get_proxy_for_url("https://cran.r-project.org")
Sys.setenv(https_proxy = proxy, http_proxy = proxy)

utils::download.file(
  "https://cran.r-project.org/src/base/NEWS",
  tempfile(),
  quiet = TRUE
)
```

### Permanent fix — add to `~/.Renviron`

```r
# Run this once to auto-detect and persist the proxy:
proxy <- curl::ie_get_proxy_for_url("https://cran.r-project.org")
cat(sprintf('https_proxy="%s"\nhttp_proxy="%s"\n', proxy, proxy),
    file = "~/.Renviron", append = TRUE)
```

Then restart R. Verify with:

```r
Sys.getenv("https_proxy")
```

> **Note:** If your network uses different proxies for different destinations
> (common with PAC files), you may need to run `ie_get_proxy_for_url()` for each
> domain and set the most permissive one, or ask IT for the direct PAC file URL.

---

## Problem 1 + 2 combined (most common corporate setup)

Apply both fixes together in `~/.Renviron`:

```
R_LIBCURL_SSL_REVOKE_BEST_EFFORT=TRUE
https_proxy=http://proxy.corp.com:8080
http_proxy=http://proxy.corp.com:8080
```

---

## Step 4 — Verify pak works end-to-end

After applying fixes, restart R and run:

```r
# Basic connectivity
utils::download.file(
  "https://cran.r-project.org/src/base/NEWS",
  tempfile(),
  quiet = TRUE
)
message("download.file: OK")

# pak's own download helper (uses bundled curl as primary)
pak:::pak_download_file(
  "https://cran.r-project.org/src/base/NEWS",
  tempfile(),
  quiet = TRUE
)
message("pak_download_file: OK")

# pak metadata fetch (exercises pak_update path)
meta <- pak:::pak_repo_metadata()
message(sprintf("pak_repo_metadata: OK (%d entries)", nrow(meta)))

# Full package install
pak::pkg_install("jsonlite")
message("pak::pkg_install: OK")
```

---

## Step 5 — Run the automated simulation

This script temporarily disables `utils::download.file` and verifies pak's
curl-based fallback works:

```r
# from the repository root:
source("tools/test-corporate-env.R")
```

Expected output:

```
=== Corporate environment download simulation ===
[test 1] Confirm utils::download.file fails...  PASS
[test 2] pak_download_file should succeed via curl despite the block...  PASS
[test 3] pak_repo_metadata() fetch via pak_download_file...  PASS
=== All tests passed ===
```

---

## Quick reference

| Symptom | Root cause | Fix |
|---|---|---|
| `SSL connect error` / `SSL certificate problem` | Schannel revocation check on MITM proxy | `R_LIBCURL_SSL_REVOKE_BEST_EFFORT=TRUE` in `.Renviron` |
| `Could not connect` / `Connection refused` / times out | PAC/WPAD proxy not detected | `https_proxy=<proxy>` in `.Renviron` |
| curl works, download.file fails, both of the above tried | pak not using bundled curl | Load dev pak with `devtools::load_all()` or install from `SermetPekin/pak@dev2` |
| Everything fails including curl | Network blocks all R traffic | Ask IT to whitelist `cran.r-project.org`, `r-lib.github.io` |

---

## Installing the patched pak from this branch

If the `.Renviron` fixes are not enough (e.g. on a machine you cannot modify system
settings on), the patched pak routes all its downloads through its own bundled curl
library, bypassing `utils::download.file` entirely:

```r
# Install the patched version directly (curl must at least work):
pak::pkg_install("SermetPekin/pak@dev2")
```

Or load it in development mode:

```r
devtools::load_all("/path/to/pak")
```
