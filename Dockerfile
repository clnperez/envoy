FROM bazel:0.10.1

RUN apt-get install -y git golang-go cmake automake wget libtool m4 sudo
ENV GO_VERSION 1.9.4
RUN curl -fsSL "https://golang.org/dl/go${GO_VERSION}.linux-ppc64le.tar.gz" \
    | tar -xzC /usr/local
ENV PATH /go/bin:/usr/local/go/bin:$PATH
ENV GOPATH /go
RUN useradd -m -u 1001 user
WORKDIR /home/user/go/github.com/envoyproxy/envoy
# RUN bazel fetch //source/...
# CMD bazel build --verbose_failures --copt="-Wno-error=cpp" --copt="-Wl,dw" //source/exe:envoy-static &> build_envoy_static.out
CMD /bin/bash
