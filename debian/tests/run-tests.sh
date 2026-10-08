#!/bin/bash

set -ex

PROGRAM=$(basename "$0")
TARGET=${PROGRAM}

# The autopkgtests are run in throwaway environments, let's be good citizens
# regardless, and attempt to clean up any environment modifications.
function cleanup {
    rc=$?

    set +e

    # Dump the log to console on error
    if [ $rc -ne 0 ]; then
        for logfile in ./tests/system-*-testsuite.log; do
            printf "%s:\n" "$(basename "$logfile")"
            cat "$logfile"
        done
    fi

    # The DPDK test requires post-test cleanup steps.
    if [ "$PROGRAM" = "dpdk" ]; then
        mv /etc/dpdk/dpdk.conf.bak /etc/dpdk/dpdk.conf
        systemctl restart dpdk

        update-alternatives \
            --set ovs-vswitchd \
            /usr/lib/openvswitch-switch/ovs-vswitchd

        if dirs +1 > /dev/null 2>&1; then
            popd
            umount "${BIND_MOUNT_DIR}"
            rmdir "${BIND_MOUNT_DIR}"
        fi
    fi

    exit $rc
}
trap cleanup EXIT

# Ensure none of the Open vSwitch or Open Virtual Network daemons are running.
systemctl stop \
    ovs-vswitchd \
    ovsdb-server \
    ovn-central \
    ovn-controller \
    ovn-host \
    ovn-northd \
    ovn-ovsdb-server-nb \
    ovn-ovsdb-server-sb

# Depending on which test suite should run, having the kernel datapath active
# may conflict with the test.
#
# The test suite that checks the kernel datapath has provisions to enable it at
# runtime.
ovs-dpctl del-dp system@ovs-system || true
modprobe -r openvswitch

# The OVN system test suite relies on behavior of the NMAP projects
# reimplementation of Netcat.
apt-get remove --yes --purge netcat-openbsd || true
ln -sf /usr/bin/ncat /usr/bin/nc

# The DPDK test requires preparing steps.
if [ "$PROGRAM" = "dpdk" ]; then
    if [ ! -x /usr/lib/openvswitch-switch-dpdk/ovs-vswitchd-dpdk ]; then
        echo "DPDK enabled binary not detected, SKIP test"
        exit 77
    fi
    ARCH=$(dpkg --print-architecture)
    echo "Check required features on arch: ${ARCH}"
    case "${ARCH}" in
        amd64)
            # For amd64 the OVS DPDK support works with ssse3
            # https://github.com/openvswitch/ovs/blob/8045c0f8de5192355ca438ed7eef77457c3c1625/acinclude.m4#LL441C52-L441C52
            if ! grep -q '^flags.*sse3' /proc/cpuinfo; then
                echo "Missing ssse3 on ${ARCH} - not supported, SKIP test"
                exit 77
            fi
            ;;
        arm64)
            if ! grep -q '^Features.*crc32' /proc/cpuinfo; then
                echo "Missing crc32 on ${ARCH} - not supported, SKIP test"
                exit 77
            fi
            ;;
    esac
    echo "no known missing feature on ${ARCH}, continue test"

    # Allocate hugepages, use 2M pages when possible because of higher
    # probability of successful allocation at runtime and smaller test
    # footprint in CI virtual machines.
    #
    # If the tests are to be run on real physical hardware, you may need
    # to adjust these variables depending on CPU architecture and topology.
    numa_node=$(lscpu | awk '/NUMA node\(s\)/{print$3}')
    if [ -z "$numa_node" ] || [ "$numa_node" -eq 0 ]; then
        numa_node=1
    fi
    case "${ARCH}" in
        arm64)
            # Avoid DPDK erroring out with "couldn't find suitable memseg_list"
            # (LP: #2059400).
            DPDK_NR_1G_PAGES=${DPDK_NR_1G_PAGES:-$((numa_node * 1))}

            # We need to allocate at least one 2M hugepage because the system
            # default hugepagesize is most likely 2M and consequently what
            # shows up in /proc/meminfo used by the test.
            #
            # https://github.com/ovn-org/ovn/blob/dc52bf70cb7e/tests/system-dpdk-macros.at#L18-L29
            DPDK_NR_2M_PAGES=${DPDK_NR_2M_PAGES:-1}
            ;;
        *)
            DPDK_NR_1G_PAGES=${DPDK_NR_1G_PAGES:-0}
            DPDK_NR_2M_PAGES=${DPDK_NR_2M_PAGES:-$((numa_node * (2667 + 512) / 2))}
            ;;
    esac

    printf "Determine hugepage allocation for %s NUMA Node(s) on arch: %s\n" \
        "${numa_node}" "${ARCH}"
    echo "DPDK_NR_2M_PAGES=${DPDK_NR_2M_PAGES}"
    echo "DPDK_NR_1G_PAGES=${DPDK_NR_1G_PAGES}"

    mv /etc/dpdk/dpdk.conf /etc/dpdk/dpdk.conf.bak
    cat << EOF > /etc/dpdk/dpdk.conf
NR_1G_PAGES=${DPDK_NR_1G_PAGES}
NR_2M_PAGES=${DPDK_NR_2M_PAGES}
DROPCACHE_BEFORE_HP_ALLOC=1
EOF
    systemctl restart dpdk
    realhp_2m=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages)
    realhp_1g=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages)
    if [ "$realhp_2m" != "$DPDK_NR_2M_PAGES" ] || \
       [ "$realhp_1g" != "$DPDK_NR_1G_PAGES" ]; then
        echo "Unable to allocate huge pages required for the test, SKIP test"
        exit 77
    fi

    # Point `ovs-vswitchd` at the DPDK enabled binary.
    update-alternatives \
        --set ovs-vswitchd \
        /usr/lib/openvswitch-switch-dpdk/ovs-vswitchd-dpdk

    # Long log messages from DPDK library overflow and is written as multiple
    # lines.  This does not play well with the OVS testsuite assertions.  Even
    # a tmp directory in /tmp will make the paths too long.
    #
    # Realpaths from build will be embedded in testsuite artifacts, so we do
    # this before the build, and use a bind mount to avoid copying data around
    # (using a symlink would not be sufficient).
    #
    # Ensure we use a short path for running the testsuite (LP:# 2019069).
    BIND_MOUNT_DIR=$(mktemp -d /XXX)
    mount --bind . "${BIND_MOUNT_DIR}"
    pushd "${BIND_MOUNT_DIR}"
fi

# List of tests to run, an empty list means run all tests.
TEST_LIST=${TEST_LIST:-""}

# Run the testsuite.
#
# By not having paths from build directory in AUTOTEST_PATH, apart from
# `tests`, will ensure binaries are executed from system PATH, i.e. from the
# binary package under test, and not the built source tree.
#
# Note that the built testsuite artifacts are put under tests/ in the top level
# source directory regardless of the use of `make -C ...` in the package
# source.  The testsuite's configuration (atlocal) is however placed in
# relation to the value of `-C`.
#
# We also cannot use `make` to invoke the testsuite, as we have removed the
# build dependencies, and `make` will notice the missing sytem headers.
#
# The sum of this leads to the invocation method below.
for testsuite in ${TARGET}; do
    if [ -z "${TEST_LIST}" ] && \
       [ -f "debian/tests/${testsuite}-skip-tests.txt" ]; then
        TEST_LIST=$(debian/testlist.py - \
                    "tests/system-${testsuite}-testsuite" \
                    < "debian/tests/${testsuite}-skip-tests.txt")
    fi

    set /bin/bash "tests/system-${testsuite}-testsuite" \
            -C tests \
            -j1 \
            AUTOTEST_PATH="$(realpath ./tests)":"$(realpath ./ovs/tests)" \
            ovs_srcdir="$(realpath ./ovs)"
    # We cannot double quote the TEST_LIST variable below as that would make
    # bash put single quotes around it for empty test list, which autotest
    # does not understand.
    #
    # shellcheck disable=SC2086
    "$@" ${TEST_LIST} || "$@" --recheck
done
