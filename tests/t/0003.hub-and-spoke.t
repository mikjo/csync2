#!/bin/bash

. $(dirname $0)/../include.sh

# That prepared some "node names" ($N1 .. $N9) and corresponding
# IPv4 addresses in /etc/hosts ($IP1 .. $IP9, 127.2.1.1 -- *.9)
# as well as variables $D1 .. $D9 to point to the respective sub tree
# of those "test node" instances.

# Cleanup does clean the data base and the test directories.
cleanup

# N1 will be the hub
# N2, N3, and N4 will be the spokes
#

# populate $D1
# ------------

create_configs()
{
	# Hub configuration
        cat >"$CSYNC2_SYSTEM_DIR/csync2_hub.cfg" <<-___
group demo
{
	host 1.csync2.test;
	host 2.csync2.test;
	host 3.csync2.test;
	host 4.csync2.test;

	key csync2.key_demo;

	include %demodir%;
	exclude %demodir%/e;

        auto younger;
}

prefix demodir
{
	on 1.csync2.test: $TESTS_DIR/1;
	on 2.csync2.test: $TESTS_DIR/2;
	on 3.csync2.test: $TESTS_DIR/3;
	on 4.csync2.test: $TESTS_DIR/4;
}

nossl * *;
___

	# Spoke configuration
        for i in 2 3 4 ; do
            cat >"$CSYNC2_SYSTEM_DIR/csync2_n$i.cfg" <<-___
group demo
{
	host 1.csync2.test;
	host $i.csync2.test;

	key csync2.key_demo;

	include %demodir%;
	exclude %demodir%/e;

        auto first;
}

prefix demodir
{
	on 1.csync2.test: $TESTS_DIR/1;
	on $i.csync2.test: $TESTS_DIR/$i;
}

nossl * *;
___
	done
}


populate_all()
{
	(
        set -xe
        mkdir $D1/a
        date > $D1/a/initial
        cp -a $D1/a $D2
        cp -a $D1/a $D3
        cp -a $D1/a $D4
	)
}

populate_d1()
{
        date > $D1/a/new
}

TEST	"create configs" create_configs
TEST	"pre-populate all" populate_all
TEST	"diff 1-2"	diff -rq $D1 $D2
TEST	"diff 1-3"	diff -rq $D1 $D3
TEST	"diff 1-4"	diff -rq $D1 $D4
TEST	"mark 1 synced hub"	csync2 -C hub -N $N1 -cIr $D1
TEST	"mark 2 synced"	csync2 -C n2  -N $N2 -cIr $D2
TEST	"mark 3 synced"	csync2 -C n3  -N $N3 -cIr $D3
TEST	"mark 4 synced"	csync2 -C n4  -N $N4 -cIr $D4

# Two directories and one file
t() { [[ $(csync2 -C hub -N $N1 -L | wc -l) = 3 ]] ; }
TEST	"list db 1"	t

TEST	"populate D1"	populate_d1
TEST	"check"		csync2 -C hub -N $N1 -cr $D1
# one new file for each machine
t() { [[ $(csync2 -C hub -N $N1 -M | wc -l) = 3 ]] ; }
TEST	"list dirty"	t

# compare and sync between instances
# ----------------------------------
# because N4 is not reachable, this should exit with exit code 1
TEST_EXPECT_EXIT_CODE	1	"csync2 -uv partial"	csync2_u ${N1}:hub ${N2}:n2 ${N3}:n3
TEST	"diff -rq D2"	diff -rq $D1 $D2
TEST	"diff -rq D3"	diff -rq $D1 $D3
TEST_EXPECT_EXIT_CODE	1 "diff -rq D4 fail"	diff -rq $D1 $D4
# all "dirty" hosts (N4) are reachable, so now it should succeed
TEST	"csync2 -uv complete"	csync2_u ${N1}:hub ${N4}:n4
TEST	"diff -rq D4 succeed"	diff -rq $D1 $D4


# add a file on one client
# ------------------------

populate_d2()
{
        date > $D2/a/c1
}
TEST	"populate D2 c1"	populate_d2
TEST_EXPECT_EXIT_CODE	1 "diff -rq D2 fail c2"	diff -rq $D1 $D2
TEST	"check 2"	csync2 -C n2 -N $N2 -cr $D2
TEST	"csync2 -uv inbound"	csync2_u ${N2}:n2 ${N1}:hub
TEST	"diff -rq D2 succeed c1"	diff -rq $D1 $D2
TEST_EXPECT_EXIT_CODE	1 "diff -rq D4 fail c1"	diff -rq $D1 $D4
TEST	"check hub c1"		csync2 -C hub -N $N1 -cr $D1
TEST	"csync2 -uv ALL c1"	csync2_u ${N1}:hub ${N2}:n2 ${N3}:n3 ${N4}:n4
TEST	"diff -rq D2 c1"	diff -rq $D1 $D2
TEST	"diff -rq D3 c1"	diff -rq $D1 $D3
TEST	"diff -rq D4 c1"	diff -rq $D1 $D4

# create a conflict and make sure it auto-resolves
# ------------------------------------------------
populate_conflict()
{
	(
        set -xe
        # ensure that all content really conflicts
        (echo $1; date '+%s.%N') > $1/a/conflict
        touch -d $2 $1/a/conflict
	)
}
TEST	"populate d3 conflict"	populate_conflict $D3 '6 second ago'
TEST	"populate d1 conflict"	populate_conflict $D1 '4 seconds ago'
TEST	"populate d2 conflict"	populate_conflict $D2 '2 seconds ago'
TEST_EXPECT_EXIT_CODE	1 "diff -rq D1D2 fail"	diff -rq $D1 $D2
TEST_EXPECT_EXIT_CODE	1 "diff -rq D2D3 fail"	diff -rq $D2 $D3
TEST	"check 2"	csync2 -C n2 -N $N2 -cr $D2
TEST	"check 3"	csync2 -C n3 -N $N3 -cr $D3
TEST	"csync2 -uv inbound"	csync2_u ${N2}:n2 ${N1}:hub
TEST	"diff -rq D2 succeed 1 "	diff -rq $D1 $D2
TEST_EXPECT_EXIT_CODE	1 "diff -rq D3 fail"	diff -rq $D1 $D3
TEST	"csync2 -uv inbound"	csync2_u ${N3}:n3 ${N1}:hub
TEST	"diff -rq D3 succeed 1"	diff -rq $D1 $D3
TEST_EXPECT_EXIT_CODE	1 "diff -rq D1D2 fail"	diff -rq $D1 $D2
TEST	"check hub"		csync2 -C hub -N $N1 -cr $D1
TEST	"csync2 -uv outbound"	csync2_u ${N1}:hub ${N2}:n2 ${N3}:n3 ${N4}:n4
TEST	"diff -rq D2 succeed 2"	diff -rq $D1 $D2
TEST	"diff -rq D3 succeed 3"	diff -rq $D1 $D3
TEST	"diff -rq D4 succeed"	diff -rq $D1 $D4


# remove a file, propagate removal
# --------------------------------
assert_no_conflict()
{
	(
        set -xe
        for i in $* ; do
		[ ! -f $i/a/conflict ]
        done
	)
}
TEST	"update hub context db"	csync2 -C hub -N $N1 -cr $D1
TEST	"record conflict file on d2"	csync2 -C n2 -N $N2 -cr $D2
TEST	"remove d2 conflict"	rm $D2/a/conflict
TEST	"assert no conflict D2"	assert_no_conflict $D2
TEST_EXPECT_EXIT_CODE	1 "assert no conflict D1"	assert_no_conflict $D1
TEST_EXPECT_EXIT_CODE	1 "diff -rq D1D2 fail"	diff -rq $D1 $D2
TEST	"record conflict file deletion"	csync2 -C n2 -N $N2 -cr $D2
TEST	"csync2 -uv inbound"	csync2_u ${N2}:n2 ${N1}:hub
TEST	"assert no conflict D1"	assert_no_conflict $D1
TEST	"check hub"		csync2 -C hub -N $N1 -cr $D1
TEST	"csync2 -uv outbound"	csync2_u ${N1}:hub ${N2}:n2 ${N3}:n3 ${N4}:n4
TEST	"diff -rq D2 succeed"	diff -rq $D1 $D2
TEST	"diff -rq D3 succeed"	diff -rq $D1 $D3
TEST	"diff -rq D4 succeed"	diff -rq $D1 $D4
TEST	"assert no conflict ALL"	assert_no_conflict $D1 $D2 $D3 $D4
