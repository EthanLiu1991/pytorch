# syntax = docker/dockerfile:experimental
#
# NOTE: To build this you will need a docker version > 18.06 with
#       experimental enabled and DOCKER_BUILDKIT=1
#
#       If you do not use buildkit you are not going to have a good time
#
#       For reference:
#           https://docs.docker.com/develop/develop-images/build_enhancements/
ARG BASE_IMAGE=ubuntu:18.04
ARG PYTHON_VERSION=3.7

FROM ${BASE_IMAGE} as dev-base
RUN --mount=type=cache,id=apt-dev,target=/var/cache/apt \
    apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        ccache \
#        cmake \
        curl \
        git \
        libjpeg-dev \
	wget \
	unzip \
        libpng-dev && \
    rm -rf /var/lib/apt/lists/*

#RUN wget http://ftp.tsukuba.wide.ad.jp/software/gcc/releases/gcc-7.3.0/gcc-7.3.0.tar.gz && \
#tar -zxf gcc-7.3.0.tar.gz && \
#cd gcc-7.3.0/ && \
#./contrib/download_prerequisites && \
#./configure --enable-checking=release --enable-languages=c,c++ --disable-multilib && \
#make -j 12 && make install && \
#rm -rf /usr/bin/gcc && rm -rf /usr/bin/g++ && ln -s /usr/local/bin/gcc /usr/bin/gcc && ln -s /usr/local/bin/g++ /usr/bin/g++

RUN wget https://cmake.org/files/v3.13/cmake-3.13.0.tar.gz && \
tar -zxf cmake-3.13.0.tar.gz && \
cd cmake-3.13.0/ && \
./bootstrap && \
make -j 16 && make install

RUN /usr/sbin/update-ccache-symlinks
RUN mkdir /opt/ccache && ccache --set-config=cache_dir=/opt/ccache
ENV PATH /opt/conda/bin:$PATH

FROM dev-base as conda
ARG PYTHON_VERSION=3.7
RUN curl -fsSL -v -o ~/miniconda.sh -O  https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh  && \
    chmod +x ~/miniconda.sh && \
    ~/miniconda.sh -b -p /opt/conda && \
    rm ~/miniconda.sh && \
    /opt/conda/bin/conda install -y python=${PYTHON_VERSION} conda-build pyyaml numpy ipython&& \
    /opt/conda/bin/conda clean -ya

FROM dev-base as submodule-update
WORKDIR /opt/pytorch
COPY . .
#RUN git submodule update --init --recursive --jobs 0

FROM conda as build
WORKDIR /opt/pytorch
COPY --from=conda /opt/conda /opt/conda
COPY --from=submodule-update /opt/pytorch /opt/pytorch

RUN /opt/conda/bin/pip install typing_extensions

RUN --mount=type=cache,target=/opt/ccache \
# ethanliu modify
#    TORCH_CUDA_ARCH_LIST="3.5 5.2 6.0 6.1 7.0+PTX 8.0" TORCH_NVCC_FLAGS="-Xfatbin -compress-all" \
    TORCH_CUDA_ARCH_LIST="3.5 5.2 6.0 6.1 7.0+PTX 7.5" TORCH_NVCC_FLAGS="-Xfatbin -compress-all" \
    MAX_JOBS=12 \
#
    CMAKE_PREFIX_PATH="$(dirname $(which conda))/../" \
    python setup.py install

FROM conda as conda-installs
ARG PYTHON_VERSION=3.7
ARG CUDA_VERSION=10.2
ARG CUDA_CHANNEL=nvidia
# ethanliu add
ARG PYTORCH_VERSION=1.10.0
#
ARG INSTALL_CHANNEL=pytorch-nightly
ENV CONDA_OVERRIDE_CUDA=${CUDA_VERSION}
RUN /opt/conda/bin/conda install -c "${INSTALL_CHANNEL}" -c "${CUDA_CHANNEL}" -y python=${PYTHON_VERSION} pytorch=${PYTORCH_VERSION} torchvision torchtext "cudatoolkit=${CUDA_VERSION}" && \
    /opt/conda/bin/conda clean -ya
RUN /opt/conda/bin/pip install torchelastic

FROM ${BASE_IMAGE} as official
ARG PYTORCH_VERSION
LABEL com.nvidia.volumes.needed="nvidia_driver"
RUN --mount=type=cache,id=apt-final,target=/var/cache/apt \
    apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        libjpeg-dev \
        libpng-dev && \
    rm -rf /var/lib/apt/lists/*
COPY --from=conda-installs /opt/conda /opt/conda
ENV PATH /opt/conda/bin:$PATH
ENV NVIDIA_VISIBLE_DEVICES all
ENV NVIDIA_DRIVER_CAPABILITIES compute,utility
ENV LD_LIBRARY_PATH /usr/local/nvidia/lib:/usr/local/nvidia/lib64
ENV PYTORCH_VERSION ${PYTORCH_VERSION}
WORKDIR /workspace

FROM official as dev
# Should override the already installed version from the official-image stage
COPY --from=build /opt/conda /opt/conda
