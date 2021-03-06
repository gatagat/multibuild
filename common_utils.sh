#!/bin/bash
# Utilities for both OSX and Docker Linux
# Python should be on the PATH

# Only source common_utils once
if [ -n "$COMMON_UTILS_SOURCED" ]; then
    return
fi
COMMON_UTILS_SOURCED=1

# Turn on exit-if-error
set -e

MULTIBUILD_DIR=$(dirname "${BASH_SOURCE[0]}")
if [ $(uname) == "Darwin" ]; then IS_OSX=1; fi

# Work round bug in travis xcode image described at
# https://github.com/direnv/direnv/issues/210
shell_session_update() { :; }

function abspath {
    python -c "import os.path; print(os.path.abspath('$1'))"
}

function relpath {
    # Path of first input relative to second (or $PWD if not specified)
    python -c "import os.path; print(os.path.relpath('$1','${2:-$PWD}'))"
}

function realpath {
    python -c "import os; print(os.path.realpath('$1'))"
}

function lex_ver {
    # Echoes dot-separated version string padded with zeros
    # Thus:
    # 3.2.1 -> 003002001
    # 3     -> 003000000
    echo $1 | awk -F "." '{printf "%03d%03d%03d", $1, $2, $3}'
}

function unlex_ver {
    # Reverses lex_ver to produce major.minor.micro
    # Thus:
    # 003002001 -> 3.2.1
    # 003000000 -> 3.0.0
    echo "$((10#${1:0:3}+0)).$((10#${1:3:3}+0)).$((10#${1:6:3}+0))"
}

function strip_ver_suffix {
    echo $(unlex_ver $(lex_ver $1))
}

function is_function {
    # Echo "true" if input argument string is a function
    # Allow errors during "set -e" blocks.
    (set +e; echo $($(declare -Ff "$1") > /dev/null && echo true))
}

function gh-clone {
    git clone https://github.com/$1
}

function rm_mkdir {
    # Remove directory if present, then make directory
    local path=$1
    if [ -z "$path" ]; then echo "Need not-empty path"; exit 1; fi
    if [ -d "$path" ]; then rm -rf $path; fi
    mkdir $path
}

function untar {
    local in_fname=$1
    if [ -z "$in_fname" ];then echo "in_fname not defined"; exit 1; fi
    local extension=${in_fname##*.}
    case $extension in
        tar) tar -xf $in_fname ;;
        gz|tgz) tar -zxf $in_fname ;;
        bz2) tar -jxf $in_fname ;;
        zip) unzip $in_fname ;;
        xz) unxz -c $in_fname | tar -xf ;;
        *) echo Did not recognize extension $extension; exit 1 ;;
    esac
}

function fetch_unpack {
    # Fetch input archive name from input URL
    # Parameters
    #    url - URL from which to fetch archive
    #    archive_fname (optional) archive name
    #
    # If `archive_fname` not specified then use basename from `url`
    # If `archive_fname` already present at download location, use that instead.
    local url=$1
    if [ -z "$url" ];then echo "url not defined"; exit 1; fi
    local archive_fname=${2:-$(basename $url)}
    local arch_sdir="${ARCHIVE_SDIR:-archives}"
    # Make the archive directory in case it doesn't exist
    mkdir -p $arch_sdir
    local out_archive="${arch_sdir}/${archive_fname}"
    # Fetch the archive if it does not exist
    if [ ! -f "$out_archive" ]; then
        curl -L $url > $out_archive
    fi
    # Unpack archive, refreshing contents
    rm_mkdir arch_tmp
    (cd arch_tmp && untar ../$out_archive && rsync --delete -avh * ..)
}

function clean_code {
    local repo_dir=${1:-$REPO_DIR}
    local build_commit=${2:-$BUILD_COMMIT}
    [ -z "$repo_dir" ] && echo "repo_dir not defined" && exit 1
    [ -z "$build_commit" ] && echo "build_commit not defined" && exit 1
    # The package $repo_dir may be a submodule. git submodules do not
    # have a .git directory. If $repo_dir is copied around, tools like
    # Versioneer which require that it be a git repository are unable
    # to determine the version.  Give submodule proper git directory
    fill_submodule "$repo_dir"
    (cd $repo_dir \
        && git fetch origin \
        && git checkout $build_commit \
        && git clean -fxd \
        && git reset --hard \
        && git submodule update --init --recursive)
}

function build_wheel_cmd {
    # Builds wheel with named command, puts into $WHEEL_SDIR
    #
    # Parameters:
    #     cmd  (optional, default "pip_wheel_cmd"
    #        Name of command for building wheel
    #     repo_dir  (optional, default $REPO_DIR)
    #
    # Depends on
    #     REPO_DIR  (or via input argument)
    #     WHEEL_SDIR  (optional, default "wheelhouse")
    #     BUILD_DEPENDS (optional, default "")
    #     MANYLINUX_URL (optional, default "") (via pip_opts function)
    local cmd=${1:-pip_wheel_cmd}
    local repo_dir=${2:-$REPO_DIR}
    [ -z "$repo_dir" ] && echo "repo_dir not defined" && exit 1
    local wheelhouse=$(abspath ${WHEEL_SDIR:-wheelhouse})
    if [ -n "$(is_function "pre_build")" ]; then pre_build; fi
    if [ -n "$BUILD_DEPENDS" ]; then
        pip install $(pip_opts) $BUILD_DEPENDS
    fi
    (cd $repo_dir && $cmd $wheelhouse)
    repair_wheelhouse $wheelhouse
}

function pip_wheel_cmd {
    local abs_wheelhouse=$1
    pip wheel $(pip_opts) -w $abs_wheelhouse --no-deps .
}

function bdist_wheel_cmd {
    # Builds wheel with bdist_wheel, puts into wheelhouse
    #
    # It may sometimes be useful to use bdist_wheel for the wheel building
    # process.  For example, versioneer has problems with versions which are
    # fixed with bdist_wheel:
    # https://github.com/warner/python-versioneer/issues/121
    local abs_wheelhouse=$1
    python setup.py bdist_wheel
    cp dist/*.whl $abs_wheelhouse
}

function build_pip_wheel {
    # Standard wheel building command with pip wheel
    build_wheel_cmd "pip_wheel_cmd" $@
}

function build_bdist_wheel {
    # Wheel building with bdist_wheel. See bdist_wheel_cmd
    build_wheel_cmd "bdist_wheel_cmd" $@
}

function build_wheel {
    # Set default building method to pip
    build_pip_wheel $@
}

function build_index_wheel {
    # Builds wheel from some index, usually pypi
    #
    # Parameters:
    #     project_spec
    #        requirement to install, e.g. "tornado" or "tornado==4.4.1"
    #     *args
    #        Any other arguments to be passed to pip `install`  and `wheel`
    #        commands.
    #
    # Depends on
    #     WHEEL_SDIR  (optional, default "wheelhouse")
    #     BUILD_DEPENDS (optional, default "")
    #     MANYLINUX_URL (optional, default "") (via pip_opts function)
    #
    # You can also override `pip_opts` command to set indices other than pypi
    local project_spec=$1
    [ -z "$project_spec" ] && echo "project_spec not defined" && exit 1
    # Discard first argument to pass remainder to pip
    shift
    local wheelhouse=$(abspath ${WHEEL_SDIR:-wheelhouse})
    if [ -n "$(is_function "pre_build")" ]; then pre_build; fi
    if [ -n "$BUILD_DEPENDS" ]; then
        pip install $(pip_opts) $@ $BUILD_DEPENDS
    fi
    pip wheel $(pip_opts) $@ -w $wheelhouse --no-deps $project_spec
    repair_wheelhouse $wheelhouse
}

function pip_opts {
    [ -n "$MANYLINUX_URL" ] && echo "--find-links $MANYLINUX_URL"
}

function get_platform {
    # Report platform as given by uname
    python -c 'import platform; print(platform.uname()[4])'
}

function install_wheel {
    # Install test dependencies and built wheel
    #
    # Pass any input flags to pip install steps
    #
    # Depends on:
    #     WHEEL_SDIR  (optional, default "wheelhouse")
    #     TEST_DEPENDS  (optional, default "")
    #     MANYLINUX_URL (optional, default "") (via pip_opts function)
    local wheelhouse=$(abspath ${WHEEL_SDIR:-wheelhouse})
    if [ -n "$TEST_DEPENDS" ]; then
        pip install $(pip_opts) $@ $TEST_DEPENDS
    fi
    # Install compatible wheel
    pip install $(pip_opts) $@ \
        $(python $MULTIBUILD_DIR/supported_wheels.py $wheelhouse/*.whl)
}

function install_run {
    # Depends on function `run_tests` defined in `config.sh`
    install_wheel
    mkdir tmp_for_test
    (cd tmp_for_test && run_tests)
}

function fill_submodule {
    # Restores .git directory to submodule, if necessary
    # See:
    # http://stackoverflow.com/questions/41776331/is-there-a-way-to-reconstruct-a-git-directory-for-a-submodule
    local repo_dir="$1"
    [ -z "$repo_dir" ] && echo "repo_dir not defined" && exit 1
    local git_loc="$repo_dir/.git"
    # For ordinary submodule, .git is a file.
    [ -d "$git_loc" ] && return
    # Need to recreate .git directory for submodule
    local origin_url=$(cd "$repo_dir" && git config --get remote.origin.url)
    local repo_copy="$repo_dir-$RANDOM"
    git clone --recursive "$repo_dir" "$repo_copy"
    rm -rf "$repo_dir"
    mv "${repo_copy}" "$repo_dir"
    (cd "$repo_dir" && git remote set-url origin $origin_url)
}

PYPY_URL=https://bitbucket.org/pypy/pypy/downloads

# As of 2017-03-25, the latest verions of PyPy.
LATEST_PP_1=1.9

LATEST_PP_2=2.6
LATEST_PP_2p0=2.0.2
LATEST_PP_2p2=2.2.1
LATEST_PP_2p3=2.3.1
LATEST_PP_2p4=2.4.0
LATEST_PP_2p5=2.5.1
LATEST_PP_2p6=2.6.1

LATEST_PP_4=4.0
LATEST_PP_4p0=4.0.1

LATEST_PP_5=5.7
LATEST_PP_5p0=5.0.1
LATEST_PP_5p1=5.1.1
LATEST_PP_5p3=5.3.1
LATEST_PP_5p4=5.4.1
LATEST_PP_5p6=5.6.0
LATEST_PP_5p7=5.7.0

function unroll_version {
    # Convert major or major.minor format to major.minor.micro using the above
    # values recursively
    # Parameters:
    #   $prefix : one of LATEST_PP or LATEST_PP3
    #   $version : major[.minor[.patch]]
    # Hence:
    #   LATEST_PP 5 -> 5.7.0
    #   LATEST 2.7 -> 2.7.11
    local prefix=$1
    local ver=$2
    local latest=${prefix}_${ver//./p}
    if [ -n "${!latest}" ]; then
        echo $(unroll_version ${prefix} ${!latest})
    else
        echo $ver
    fi
}

function fill_pypy_ver {
    # Convert major or major.minor format to major.minor.micro
    # Parameters:
    #   $version : major[.minor[.patch]]
    # Hence:
    #   5 -> 5.7.0
    echo $(unroll_version LATEST_PP $1)
}

function get_pypy_build_prefix {
    # Return the file prefix of a PyPy file
    # Parameters:
    #   $version : pypy2 version number
    local version=$1
    if [[ $version =~ ([0-9]+)\.([0-9]+) ]]; then
        local major=${BASH_REMATCH[1]}
        local minor=${BASH_REMATCH[2]}
        if (( $major > 5 || ($major == 5 && $minor >= 3) )); then
            echo "pypy2-v"
        else
            echo "pypy-"
        fi
    else
        echo "error: expected version number, got $1" 1>&2
        exit 1
    fi
}
