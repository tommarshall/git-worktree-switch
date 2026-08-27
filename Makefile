test:
	./test.sh

lint:
	shellcheck wt.sh test.sh

.PHONY: test lint
