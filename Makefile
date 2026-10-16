.PHONY: all app ghostty run install clean

all: app

ghostty:
	scripts/build-ghostty.sh

app:
	scripts/bundle.sh

run: app
	open build/Vertty.app

install: app
	rm -rf /Applications/Vertty.app
	cp -R build/Vertty.app /Applications/Vertty.app
	@echo "Installed to /Applications/Vertty.app"

clean:
	rm -rf .build build/Vertty.app
