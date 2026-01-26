.PHONY: build clean run gencert

BUILD_DIR := bin
BINARY := DebugSocket

build: build-linux build-darwin

build-linux:
	GOOS=linux GOARCH=amd64 go build -o $(BUILD_DIR)/$(BINARY)_linux_amd64 .

build-darwin:
	GOOS=darwin GOARCH=arm64 go build -o $(BUILD_DIR)/$(BINARY)_darwin_arm64 .

run:
	go run . --secret=dev-secret --bind-v4=127.0.0.1:8765

run-tls: gencert
	go run . --secret=dev-secret --bind-v4=127.0.0.1:8765 --tls --cert=debugsocket.crt --key=debugsocket.key

gencert:
	go run gencert.go debugsocket

clean:
	rm -rf $(BUILD_DIR)/* debugsocket.crt debugsocket.key
