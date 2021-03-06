MYLIBS=.
COMPILER=ghc
GHCPRE=$(COMPILER) --make -O3 -i$(MYLIBS) -threaded -XGADTs
SMSC=smsc1
NETCAT=netcat

cristal: Cristal2.hs Client.hs Conf.hs JSON.hs Modules.hs PDUs.hs Util.hs
	$(GHCPRE) -o cristal Cristal2.hs

clean:
	rm -rf cristal *.hi *.o

all: cristal
	exit

test: cristal
	#   ./cristal < conf/conf.txt &
	./cristal < conf/conf.js &
	sleep 5
	$(NETCAT) localhost `tail -n 2 conf/conf.txt | head -n 1` < ../modules/logins.js

intertest:
	runhaskell Cristal2.hs < conf/conf.txt &
	$(NETCAT) localhost `tail -n 2 conf/conf.txt | head -n 1` < ../modules/logins.js
