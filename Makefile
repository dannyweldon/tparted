CC=fpc
CFLAGS=-Mobjfpc -Ci -Cr -Co -Ct -CR -Xs -Sa -gh -gw3 -gl -dTPARTED_DEBUG
CFLAGS_REL=-Ci -Cr -Co -Ct -CR -Xs -Sa -O2

build:
	mkdir -p ./bin
	mkdir -p ./output
	$(CC) -FE./bin -FU./output $(CFLAGS_REL) ./src/tparted.lpr

debug:
	mkdir -p ./bin
	mkdir -p ./output
	$(CC) -FE./bin -FU./output $(CFLAGS) ./src/tparted.lpr

clean:
	rm -rf ./bin
	rm -rf ./output

install:
	sudo cp ./bin/tparted /usr/bin/tparted

uninstall:
	sudo rm /usr/bin/tparted

test:
	mkdir -p ./bin
	mkdir -p ./output
	$(CC) -FE./bin $(CFLAGS) -FU./output -Fu./src -Fi./src ./tests/tests.lpr

conv:
	mkdir -p ./po
	rstconv -i ./output/locale.rsj -o ./po/en_US.po
	msgfmt -f ./po/ja_JP.po -o ./bin/locale/ja_JP.mo
