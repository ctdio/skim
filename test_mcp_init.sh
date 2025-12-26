#!/bin/bash

# Test MCP initialization with client capabilities

echo "Starting MCP server in background..."
./zig-out/bin/skim mcp --stdio > /tmp/mcp_response.log 2>&1 &
MCP_PID=$!

sleep 1

echo "Sending initialize request with client capabilities..."
echo '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":true,"writeTextFile":true},"terminal":true},"clientInfo":{"name":"test-client","title":"Test Client","version":"1.0.0"}}}' | nc -N localhost 9998

sleep 1

echo "Checking logs for client capabilities..."
tail -20 ~/.skim/daemon.log

echo "Cleaning up..."
kill $MCP_PID 2>/dev/null

echo "Done!"
