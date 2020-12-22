package main

import (
	"github.com/caddyserver/caddy/caddy/caddymain"

	_ "blitznote.com/src/http.upload/v3"
)

func main() {
	caddymain.Run()
}
