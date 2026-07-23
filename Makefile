.PHONY: check package

check:
	./scripts/check.sh

package: check
	./scripts/build-pkg.sh
