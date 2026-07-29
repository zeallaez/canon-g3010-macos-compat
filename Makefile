.PHONY: check package native scanner-build scanner-list signing-configure signing-status bridge-install bridge-status bridge-doctor bridge-repair bridge-uninstall clean

check:
	./scripts/check.sh

package: check
	./scripts/build-pkg.sh

native scanner-build:
	./scanner/scan.sh --build

scanner-list:
	./scanner/scan.sh --list

signing-configure:
	./scripts/configure-signing.sh

signing-status:
	./scripts/configure-signing.sh --status

bridge-install:
	./scanner/bridge/bridge.sh install

bridge-status:
	./scanner/bridge/bridge.sh status

bridge-doctor:
	./scanner/bridge/bridge.sh doctor

bridge-repair:
	./scanner/bridge/bridge.sh doctor --repair

bridge-uninstall:
	./scanner/bridge/bridge.sh uninstall

clean:
	/bin/rm -f dist/*.pkg dist/*.zip dist/SHA256SUMS
