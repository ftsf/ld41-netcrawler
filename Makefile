ld41.exe:
	nim c -d:release -o:$@ $<

ld41d.exe:
	nim c -d:debug -o:$@ $<

debug: ld41d.exe

rund: debug
	./ld41d.exe
