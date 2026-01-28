.PHONY: build clean version

VERSION := $(shell awk -F= '/^version=/{print $$2; exit}' module.prop)
OUTPUT := vpn-gateway-$(VERSION).zip

build: $(OUTPUT)

version: module.prop
	@awk -F= '/^version=/{print $$2; exit}' module.prop

$(OUTPUT): META-INF module.prop service.sh
	rm -f $(OUTPUT)
	zip -r $(OUTPUT) META-INF module.prop service.sh

clean:
	rm -rf vpn-gateway-*.zip
