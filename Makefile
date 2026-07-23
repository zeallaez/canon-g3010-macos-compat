.PHONY: check package clean

check:
	./scripts/check.sh

package: check
	./scripts/build-pkg.sh

clean:
	/bin/rm -f dist/*.pkg dist/*.zip dist/SHA256SUMS
