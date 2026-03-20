embed_ca_certs <- function(lib) {
  certfile <- file.path(lib, "pak", "curl-ca-bundle.crt")
  pak_download_file("https://curl.se/ca/cacert.pem", certfile)
}
