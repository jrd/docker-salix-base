RELEASE=14.0

salix-${RELEASE}-%.tar: make_image.sh
	@arch=$$(echo $@|sed -r 's/salix-${RELEASE}-(.*)\.tar/\1/') fakeroot ./make_image.sh --no-cache

.PHONY:
image-64: salix-${RELEASE}-x86_64.tar
	@cat $< | docker import - $$(docker info|grep ^Username:|cut -d' ' -f2)/salix-base:${RELEASE}

.PHONY:
image-32: salix-${RELEASE}-i486.tar
	@cat $< | docker import - $$(docker info|grep ^Username:|cut -d' ' -f2)/salix32-base:${RELEASE}

.PHONY:
clean:
	@rm -f *.tar
