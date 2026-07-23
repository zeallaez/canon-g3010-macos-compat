.PHONY: check package scanner-build scanner-list clean

check:
	./scripts/check.sh

package: check
	./scripts/build-pkg.sh

scanner-build:
	./scanner/scan.sh --build

scanner-list:
	./scanner/scan.sh --list

clean:
	/bin/rm -f dist/*.pkg dist/*.zip dist/SHA256SUMS
