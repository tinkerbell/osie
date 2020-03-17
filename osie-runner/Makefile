MAKEFLAGS += --no-builtin-rules
.SUFFIXES:
#.NOTPARALLEL:
.PHONY: build clean gen

build: Dockerfile requirements.txt hegel_pb2_grpc.py hegel_pb2.py run.py handlers.py log.py
	docker build -t osie-runner -f Dockerfile .

requirements.txt: requirements.in
	pip-compile --generate-hashes --output-file requirements.txt requirements.in

hegel_pb2.py: protos/hegel.proto
	python3 -m grpc_tools.protoc -Iprotos --python_out=. protos/hegel.proto

hegel_pb2_grpc.py: protos/hegel.proto
	python3 -m grpc_tools.protoc -Iprotos --grpc_python_out=. protos/hegel.proto

clean:
	rm -f hegel_pb2_grpc.py  hegel_pb2.py

