package main

import (
	"context"
	"flag"
	"github.com/grpc-ecosystem/grpc-gateway/v2/runtime"
	"google.golang.org/grpc"
	"log"
	"net/http"

	hstreamApi "github.com/hstreamdb/hstream/common/api/gen-go/HStream/Server"
	hstreamHttpServer "github.com/hstreamdb/hstream/hstream-http-server/src"
)

var (
	gRPCServerHost = flag.String("gRPCServerHost", "127.0.0.1", "gRPCServerHost")
	gRPCServerPort = flag.String("gRPCServerPort", "6570", "gRPCServerPort")
	httpServerHost = flag.String("httpServerHost", "127.0.0.1", "httpServerHost")
	httpServerPort = flag.String("httpServerPort", "6580", "httpServerPort")
	hpCtx          hstreamHttpServer.HostPortCtx
)

func main() {
	flag.Parse()
	log.Println("Server is configured with:")
	log.Printf("    gRPCServerHost: %v\n", *gRPCServerHost)
	log.Printf("    gRPCServerPort: %v\n", *gRPCServerPort)
	log.Printf("    httpServerPort: %v\n", *httpServerPort)
	hpCtx = hstreamHttpServer.HostPortCtx{
		GRPCServerHost: gRPCServerHost,
		GRPCServerPort: gRPCServerPort,
		HttpServerPort: httpServerPort,
	}

	log.Println("Setting gRPC connection")
	conn, err := grpc.DialContext(context.Background(),
		*gRPCServerHost+":"+*gRPCServerPort,
		grpc.WithInsecure())
	if err != nil {
		log.Fatalln(err)
	}
	defer func(conn *grpc.ClientConn) {
		err := conn.Close()
		if err != nil {
			panic(err)
		}
	}(conn)

	log.Println("Setting HTTP server")
	gwMux := runtime.NewServeMux()
	if err := hstreamApi.RegisterHStreamApiHandler(context.Background(),
		gwMux,
		conn); err != nil {
		log.Fatalln(err)
	}

	// Custom route for appending payloads
	err = handleAppend(gwMux)
	if err != nil {
		log.Printf("Error: %v\n", err)
	}

	gwServer := &http.Server{Addr: *httpServerHost + ":" + *httpServerPort, Handler: gwMux}
	log.Printf("Server started on port %v\n", *httpServerPort)
	log.Fatalln(gwServer.ListenAndServe())

}

// ---------------------------------------------------------------------------------------------------------------------

func handleAppend(s *runtime.ServeMux) error {
	return s.HandlePath("POST", "/streams/{streamName}:publish", hstreamHttpServer.DecodeHandler(s, &hpCtx))
}
