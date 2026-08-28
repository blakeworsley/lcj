.PHONY: build test lint check app install clean

build:
	swift build

test:
	swift run ClodexTests

lint:
	shellcheck build.sh

check: build test lint

app:
	./build.sh

install: app
	rm -rf ~/Applications/Clodex.app
	cp -R build/Clodex.app ~/Applications/Clodex.app
	open ~/Applications/Clodex.app

clean:
	rm -rf .build build
