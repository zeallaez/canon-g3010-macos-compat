.PHONY: check package scanner-build scanner-list bridge-install bridge-status bridge-uninstall clean

check:
	./scripts/check.sh

package: check
	./scripts/build-pkg.sh

scanner-build:
	./scanner/scan.sh --build

scanner-list:
	./scanner/scan.sh --list

bridge-install:
	./scanner/bridge/bridge.sh install

bridge-status:
	./scanner/bridge/bridge.sh status

bridge-uninstall:
	./scanner/bridge/bridge.sh uninstall

clean:
	/bin/rm -f dist/*.pkg dist/*.zip dist/SHA256SUMS
