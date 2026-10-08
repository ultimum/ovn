EXTRA_DIST += \
	debian/changelog \
	debian/control \
	debian/copyright \
	debian/flaky-tests-amd64.txt \
	debian/flaky-tests-arm64.txt \
	debian/flaky-tests-armel.txt \
	debian/flaky-tests-armhf.txt \
	debian/flaky-tests-i386.txt \
	debian/flaky-tests-mips64el.txt \
	debian/flaky-tests-mipsel.txt \
	debian/flaky-tests-ppc64el.txt \
	debian/flaky-tests-riscv64.txt \
	debian/flaky-tests-s390x.txt \
	debian/gbp.conf \
	debian/not-installed \
	debian/ovn-central.default \
	debian/ovn-central.install \
	debian/ovn-central.ovn-northd.service \
	debian/ovn-central.service \
	debian/ovn-common.docs \
	debian/ovn-common.install \
	debian/ovn-common.logrotate \
	debian/ovn-controller-vtep.install \
	debian/ovn-controller-vtep.service \
	debian/ovn-doc.doc-base \
	debian/ovn-doc.install \
	debian/ovn-docker.install \
	debian/ovn-host.default \
	debian/ovn-host.install \
	debian/ovn-host.ovn-controller.service \
	debian/ovn-host.service \
	debian/ovn-ic-db.install \
	debian/ovn-ic-db.service \
	debian/ovn-ic.install \
	debian/ovn-ic.service \
	debian/rules \
	debian/source/format \
	debian/source/include-binaries \
	debian/testlist.py \
	debian/watch

check-debian-changelog-version:
	@DEB_VERSION=`echo '$(VERSION)' | sed 's/pre/~pre/'`;		     \
	if $(FGREP) '($(DEB_VERSION)' $(srcdir)/debian/changelog >/dev/null; \
	then								     \
	  :;								     \
	else								     \
	  echo "Update debian/changelog to mention version $(VERSION)";	     \
	  exit 1;							     \
	fi
ALL_LOCAL += check-debian-changelog-version
DIST_HOOKS += check-debian-changelog-version
