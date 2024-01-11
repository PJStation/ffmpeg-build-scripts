#! /usr/bin/env bash
#
# Copyright (C) 2013-2014 Bilibili
# Copyright (C) 2013-2014 Zhang Rui <bbcallen@gmail.com>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

#----------
set -e
# 内部调试用
export INTERNAL_DEBUG=FALSE
. ./common.sh

#当前Linux/Windows/Mac操作系统的位数，如果是64位则填写x86_64，32位则填写x86
export FF_PC_ARCH="x86_64"

# 编译动态库，默认开启;FALSE则关闭动态库 编译静态库;动态库和静态库同时只能开启一个，建议采用动态库方式编译，因为静态方式编译存在相互引用的各个静态库因连接顺序不对导致编译错误的问题。
export FF_COMPILE_SHARED=FALSE
# libass使用Coretext还是fontconfig;TRUE代表使用CORETEXT,FALSE代表使用fontconfig
export USE_CORETEXT=TRUE
# 是否编译这些库;如果不编译将对应的值改为FALSE即可；如果ffmpeg对应的值为TRUE时，还会将其它库引入ffmpeg中，否则单独编译其它库
if [ $uname = "Darwin" ] && [ $USE_CORETEXT = "TRUE" ];then
export LIBFLAGS=(
[ffmpeg]=TRUE [x264]=TRUE [fdkaac]=TRUE [mp3lame]=TRUE [fribidi]=TRUE [freetype]=TRUE [ass]=FALSE [openssl]=TRUE
)
else
export LIBFLAGS=(
[ffmpeg]=TRUE [x264]=TRUE [fdkaac]=FALSE [mp3lame]=TRUE [fribidi]=TRUE [freetype]=TRUE [expat]=TRUE [fontconfig]=TRUE [ass]=TRUE [openssl]=TRUE
)
fi



# 是否开启ffplay ffmpeg ffprobe的编译；默认关闭
export ENABLE_FFMPEG_TOOLS=FALSE

# 是否开启硬编解码；默认开启(tips:目前只支持mac的硬编解码编译)
export ENABLE_GPU=TRUE

# $0 当前脚本的文件名
# $1 表示执行shell脚本时输入的第一个参数 比如./compile-ffmpeg-pc.sh arm64 x86_64 $1的值为arm64;$2的值为x86_64
# $# 传递给脚本或函数的参数个数。
# $* 传递给脚本或者函数的所有参数;
# $@ 传递给脚本或者函数的所有参数;
# 两者区别就是 不被双引号(" ")包含时，都以"$1" "$2" … "$n" 的形式输出所有参数。而"$*"表示"$1 $2 … $n";
# "$@"依然为"$1" "$2" … "$n"
# $$ 脚本所在的进程ID
# $? 上个命令的退出状态，或函数的返回值。一般命令返回值 执行成功返回0 失败返回1
UNI_BUILD_ROOT=`pwd`
# FF_PC_TARGET=$1
# FF_PC_ACTION=$2
FF_PC_TARGET="mac"
FF_PC_ACTION=$1
FF_PC_LIBNAME=$2
export FF_PLATFORM_TARGET=$FF_PC_TARGET

# 配置编译环境
set_toolchain_path()
{
    local ARCH=$1
    mkdir -p ${UNI_BUILD_ROOT}/build/$FF_PLATFORM_TARGET-$ARCH/pkgconfig
    export PKG_CONFIG_PATH=${UNI_BUILD_ROOT}/build/$FF_PLATFORM_TARGET-$ARCH/pkgconfig
    export STATIC_DYLMIC="--enable-static --disable-shared"
    if [ $FF_COMPILE_SHARED = "TRUE" ];then
    export STATIC_DYLMIC="--disable-static --enable-shared"
    fi
}

real_do_compile()
{	
	CONFIGURE_FLAGS=$1
	lib=$2
	SOURCE=$UNI_BUILD_ROOT/build/forksource/$lib
	PREFIX=$UNI_BUILD_ROOT/build/$FF_PC_TARGET-$FF_PC_ARCH/$lib
	cd $SOURCE
	
	echo ""
	echo "build $lib $FF_PC_ARCH ......."
	echo "CONFIGURE_FLAGS:$CONFIGURE_FLAGS"
	echo "prefix:$PREFIX"
	echo ""
    
    set +e
    make distclean
    set -e
    
    if [ $lib = "ssl" ];then
        ./Configure \
            ${CONFIGURE_FLAGS} \
            darwin64-x86_64-cc \
            --prefix=$PREFIX
        
        make -j$(get_cpu_count) && make install_sw || exit 1
    else
        ./configure \
            ${CONFIGURE_FLAGS} \
            --prefix=$PREFIX
            
        make -j$(get_cpu_count) && make install || exit 1
    fi

	if [ $lib = "mp3lame" ];then
        create_mp3lame_package_config "${PKG_CONFIG_PATH}" "${PREFIX}"
    elif [ $lib = "freetype" ];then
        cp ${PREFIX}/lib/pkgconfig/*.pc ${PKG_CONFIG_PATH} || exit 1
    elif [ $lib = "fontconfig" ];then
        create_fontconfig_package_config "${PKG_CONFIG_PATH}" "${PREFIX}"
    else
        cp ./*.pc ${PKG_CONFIG_PATH} || exit 1
    fi
    #切回上一个目录，最后一个cd之前的目录
    cd -
}

#编译x264
do_compile_x264()
{	
	CONFIGURE_FLAGS="--enable-pic --disable-cli --enable-strip $STATIC_DYLMIC"
	real_do_compile "$CONFIGURE_FLAGS" "x264"
}

#编译fdk-aac
do_compile_fdkaac()
{
	local CONFIGURE_FLAGS="--with-pic $STATIC_DYLMIC"
	real_do_compile "$CONFIGURE_FLAGS" "fdkaac"
}
#编译mp3lame
do_compile_mp3lame()
{
	#遇到问题：mp3lame连接时提示"export lame_init_old: symbol not defined"
	#分析原因：未找到这个函数的实现
	#解决方案：删除libmp3lame.sym中的lame_init_old
	SOURCE=./build/forksource/mp3lame/include/libmp3lame.sym
	$OUR_SED "/lame_init_old/d" $SOURCE
	
	CONFIGURE_FLAGS="--disable-frontend $STATIC_DYLMIC"
	real_do_compile "$CONFIGURE_FLAGS" "mp3lame"
}
#编译ass
do_compile_ass()
{
    if [ ! -f $UNI_BUILD_ROOT/build/forksource/ass/configure ];then
        SOURCE=$UNI_BUILD_ROOT/build/forksource/ass
        cd $SOURCE
        ./autogen.sh
        cd -
    fi
    
    CONFIGURE_FLAGS="--with-pic --disable-libtool-lock $STATIC_DYLMIC --enable-fontconfig --disable-harfbuzz --disable-fast-install --disable-test --disable-profile --disable-coretext "
    if [[ $USE_CORETEXT = "TRUE" && $name = "Darwin" ]];then
    CONFIGURE_FLAGS="--with-pic --disable-libtool-lock $STATIC_DYLMIC --disable-fontconfig --disable-harfbuzz --disable-fast-install --disable-test --enable-coretext --disable-require-system-font-provider --disable-profile "
    fi
    real_do_compile "$CONFIGURE_FLAGS" "ass"
}
#编译freetype
do_compile_freetype()
{
    CONFIGURE_FLAGS="--with-pic --with-zlib --without-png --without-harfbuzz --without-bzip2 --without-fsref --without-quickdraw-toolbox --without-quickdraw-carbon --without-ats --disable-fast-install --disable-mmap --with-brotli=no $STATIC_DYLMIC "
    real_do_compile "$CONFIGURE_FLAGS" "freetype"
}
#编译fribidi
do_compile_fribidi()
{
    if [ ! -f $UNI_BUILD_ROOT/build/forksource/fribidi/configure ];then
        SOURCE=$UNI_BUILD_ROOT/build/forksource/fribidi
        cd $SOURCE
        ./autogen.sh
        cd -
    fi
    CONFIGURE_FLAGS="--with-pic $STATIC_DYLMIC --disable-fast-install --disable-debug --disable-deprecated "
    real_do_compile "$CONFIGURE_FLAGS" "fribidi"
}
#编译expact
do_compile_expat()
{
    if [ $uname == "Linux" ];then
        cd $UNI_BUILD_ROOT/build/forksource/fontconfig
        autoreconf
        cd -
    fi
    local CONFIGURE_FLAGS="--with-pic $STATIC_DYLMIC --disable-fast-install --without-docbook --without-xmlwf "
    real_do_compile "$CONFIGURE_FLAGS" "expat" $1
}
#编译fontconfig
do_compile_fontconfig()
{
    if [ $uname == "Linux" ];then
        cd $UNI_BUILD_ROOT/build/forksource/fontconfig
        autoreconf
        cd -
    fi
    local CONFIGURE_FLAGS="--with-pic $STATIC_DYLMIC --disable-fast-install --disable-rpath --disable-libxml2 --disable-docs "
    real_do_compile "$CONFIGURE_FLAGS" "fontconfig" $1
}

# 编译外部库
compile_external_lib_ifneed()
{
    for (( i=$x264;i<${#LIBS[@]};i++ ))
    do
        lib=${LIBS[i]}
        FFMPEG_DEP_LIB=$UNI_BUILD_ROOT/build/$FF_PC_TARGET-$FF_PC_ARCH/$lib/lib
        
        if [[ ${LIBFLAGS[i]} == "TRUE" ]]; then
            #如果已经已经编译过，无需重新编译，重新编译删除对应的库即可
            if [[ ! -f "${FFMPEG_DEP_LIB}/lib$lib.a" && ! -f "${FFMPEG_DEP_LIB}/lib$lib.dll.a" && ! -f "${FFMPEG_DEP_LIB}/lib$lib.so" ]] ; then
                # 编译
                if [ $lib = "fdk-aac" ];then
                    lib=fdk_aac
                fi
                do_compile_$lib
            fi
        fi
    done;
}
#编译openssl
do_compile_ssl()
{
    local CONFIGURE_FLAGS="zlib-dynamic no-shared "
    if [ $FF_COMPILE_SHARED = "TRUE" ];then
        CONFIGURE_FLAGS="zlib-dynamic no-static-engine "
    fi
    
    real_do_compile "$CONFIGURE_FLAGS" "ssl" $1
}

do_compile_ffmpeg()
{
    if [ ${LIBFLAGS[$ffmpeg]} == "FALSE" ];then
        echo "config not build ffmpeg....return"
        return
    fi
    
	FF_BUILD_NAME=ffmpeg
	FF_BUILD_ROOT=`pwd`

	# 对于每一个库，他们的./configure 他们的配置参数以及关于交叉编译的配置参数可能不一样，具体参考它的./configure文件
	# 用于./configure 的参数
	FF_CFG_FLAGS=
	# 用于./configure 关于--extra-cflags 的参数，该参数包括如下内容：
	# 1、关于cpu的指令优化
	# 2、关于编译器指令有关参数优化
	# 3、指定引用三方库头文件路径或者系统库的路径
	FF_EXTRA_CFLAGS=""
	# 用于./configure 关于--extra-ldflags 的参数
	# 1、指定引用三方库的路径及库名称 比如-L<x264_path> -lx264
	FF_EXTRA_LDFLAGS=
	
	FF_SOURCE=$FF_BUILD_ROOT/build/forksource/$FF_BUILD_NAME
	FF_PREFIX=$FF_BUILD_ROOT/build/$FF_PC_TARGET-$FF_PC_ARCH/$FF_BUILD_NAME
	mkdir -p $FF_PREFIX

	# 开始编译
	# 导入ffmpeg 的配置
	export COMMON_FF_CFG_FLAGS=
		. $FF_BUILD_ROOT/config/module.sh
	
    #硬编解码，不同平台配置参数不一样
    if [ $ENABLE_GPU = "TRUE" ] && [ $FF_PC_TARGET = "mac" ];then
        # 开启Mac/IOS的videotoolbox GPU编码
        export COMMON_FF_CFG_FLAGS="$COMMON_FF_CFG_FLAGS --enable-encoder=h264_videotoolbox"
        # 开启Mac/IOS的videotoolbox GPU解码
        export COMMON_FF_CFG_FLAGS="$COMMON_FF_CFG_FLAGS --enable-hwaccel=h264_videotoolbox"
    fi
    
	#导入ffmpeg的外部库，这里指定外部库的路径，配置参数则转移到了config/module.sh中
	EXT_ALL_LIBS=
    TYPE=a
    if [ $FF_COMPILE_SHARED = "TRUE" ];then
        TYPE=so
    fi
	#${#array[@]}获取数组长度用于循环
	for(( i=$x264;i<${#LIBS[@]};i++))
	do
		lib=${LIBS[i]};
		lib_inc_dir=$FF_BUILD_ROOT/build/$FF_PC_TARGET-$FF_PC_ARCH/$lib/include
		lib_lib_dir=$FF_BUILD_ROOT/build/$FF_PC_TARGET-$FF_PC_ARCH/$lib/lib
        lib_pkg=${LIBS_PKGS[i]};
        if [[ ${LIBFLAGS[i]} == "TRUE" ]];then

            COMMON_FF_CFG_FLAGS="$COMMON_FF_CFG_FLAGS ${LIBS_PARAM[i]}"

            FF_EXTRA_CFLAGS+=" $(pkg-config --cflags $lib_pkg)"
            FF_EXTRA_LDFLAGS+=" $(pkg-config --libs --static $lib_pkg)"
            
            EXT_ALL_LIBS="$EXT_ALL_LIBS $lib_lib_dir/lib*.$TYPE"
        fi
	done
	FF_CFG_FLAGS="$COMMON_FF_CFG_FLAGS $FF_CFG_FLAGS"
    # 遇到问题：mac编译时提示"Undefined symbols _libintl_dgettext"
    # 分析原因：因为fontconfig库依赖intl库而编译时未导入
    # 解决方案：通过编译参数"-lintl"导入即可
    if [ $uname = "Darwin" ];then
        FF_EXTRA_LDFLAGS+="$FF_EXTRA_LDFLAGS -lintl"
    fi

	# 进行裁剪
    FF_CFG_FLAGS="$FF_CFG_FLAGS";
    if [ $ENABLE_FFMPEG_TOOLS="TRUE" ];then
        FF_CFG_FLAGS="$FF_CFG_FLAGS --enable-ffmpeg --enable-ffplay --enable-ffprobe";
    fi
    
	# 开启调试;如果关闭 则注释即可
	#FF_CFG_FLAGS="$FF_CFG_FLAGS --enable-debug --disable-optimizations";
	#--------------------
	
    if [ $FF_PC_TARGET = "mac" ];then
        # 当执行过一次./configure 会在源码根目录生成config.h文件
        # which 是根据使用者所配置的 PATH 变量内的目录去搜寻可执行文件路径，并且输出该路径
        # fixbug:mac osX 10.15.4 (19E266)和Version 11.4 (11E146)生成的库在调用libx264编码的avcodec_open2()函数
        # 时奔溃(报错stack_not_16_byte_aligned_error)，添加编译参数--disable-optimizations解决问题(fix：2020.5.2)
        FF_CFG_FLAGS="$FF_CFG_FLAGS --disable-ffmpeg --disable-ffplay --disable-ffprobe --disable-optimizations";
        # FF_CFG_FLAGS="$FF_CFG_FLAGS --disable-optimizations";

    fi
    
	echo ""
	echo "--------------------"
	echo "[*] configurate ffmpeg"
	echo "--------------------"
	echo "FF_CFG_FLAGS=$FF_CFG_FLAGS"

	cd $FF_SOURCE
    set +e
    make distclean
    set -e
    ./configure $FF_CFG_FLAGS \
        --prefix=$FF_PREFIX \
        --extra-cflags="$FF_EXTRA_CFLAGS" \
        --extra-ldflags="$FF_EXTRA_LDFLAGS" \
        $STATIC_DYLMIC  \
    
	make && make install
	
    # 拷贝外部库
	for lib in $EXT_ALL_LIBS
	do
		cp -f $lib $FF_PREFIX/lib
	done
 
    if [ $INTERNAL_DEBUG = "TRUE" ];then
        cp -rf $FF_PREFIX/lib /Users/apple/devoloper/mine/ffmpeg/ffmpeg-demo/demo-mac/ffmpeglib
    fi
    
	cd -
}

usage()
{
    echo "Usage:"
    echo "  compile.sh"
    echo "  compile.sh ffmpeg"
    echo "  compile.sh ffmpeg|x264|fdkaac|"
    echo "  compile.sh clean"
    echo "  compile.sh clean-x264"
    echo "  compile.sh clean-all"
    exit 1
}

# 命令开始执行处----------
if [ "$FF_PC_TARGET" != "mac" ] && [ "$FF_PC_TARGET" != "windows" ] && [ "$FF_PC_TARGET" != "linux" ]; then
    usage
fi

# 检查是否安装了pkg-config;linux和windows才需要安装pkg-config
if [ "$FF_PC_TARGET" != "mac" ] && [ ! `which pkg-config` ]; then
    echo "check pkg-config env......"
    echo "pkg-config not found begin install....."
    apt-cyg install pkg-config || exit 1
    echo -e "check pkg-config ok......"
fi

#=== sh脚本执行开始 ==== #
case "$FF_PC_ACTION" in
    "")
        # 首次编译或者重新编译(默认只重新编译ffmpeg)
        name="ffmpeg"
        # echo "$FF_PC_ARCH"
        rm_fork_source $FF_PC_TARGET $name $FF_PC_ARCH
        rm_build $FF_PC_TARGET $name $FF_PC_ARCH


        prepare_all $FF_PC_TARGET $FF_PC_ARCH
        # 配置环境
        set_toolchain_path $FF_PC_ARCH
        
        # 先编译外部库
        compile_external_lib_ifneed
        
        # 最后编译ffmpeg
        do_compile_ffmpeg
    ;;

    clean)
        # 清除ffmpeg
        name="ffmpeg"
        # echo "$FF_PC_ARCH"
        rm_fork_source $FF_PC_TARGET $name $FF_PC_ARCH
        rm_build $FF_PC_TARGET $name $FF_PC_ARCH
    ;;

    clean-*)
        # 清除对应库forksource下的源码目录和build目录
        cleanName=${FF_PC_ACTION#clean-*}
        
        if [ $cleanName == all ]; then
            echo "all:$cleanName"
            rm -rf build
        else
            echo "cleanName:$cleanName"
            rm_fork_source $FF_PC_TARGET $cleanName $FF_PC_ARCH
            rm_build $FF_PC_TARGET $cleanName $FF_PC_ARCH
        fi
    
    ;;



    *)

        # ${LIBFLAGS[*]}和${LIBFLAGS[@]}一样
        # ${!LIBFLAGS[@]}带数组下标
        # echo "LIBFLAGS: ${LIBFLAGS["ffmpeg"]}"
        found=0
        for lib in ${!All_Resources[*]}; do
            
            name=${LIBS[$lib]}
            # echo "name: $name"
            if [[ $name == $FF_PC_ACTION ]]; then
                found=1
                rm_fork_source $FF_PC_TARGET $name $FF_PC_ARCH
                rm_build $FF_PC_TARGET $name $FF_PC_ARCH
                    
                # prepare_all $FF_PC_TARGET $FF_PC_ARCH
                copy_from_local $name
                # 配置环境
                set_toolchain_path $FF_PC_ARCH
                do_compile_$name

                break
            fi
        done

        # echo "found: $found"
        if [[ $found -eq 0 ]]; then
            usage
        fi

    ;;



esac
