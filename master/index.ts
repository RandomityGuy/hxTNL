import Turn from "node-turn";
import * as https from "node:https";
import * as http from "node:http";
import * as url from "node:url";
import process from "node:process";
import type { ServerWebSocket } from "bun";

class ServerInfo {
    socket: ServerWebSocket<unknown>;
    id: string;
    startTime: Date;
    lastUpdateTime: Date;
    constructor(
        socket: ServerWebSocket<unknown>,
        id: string
    ) {
        this.socket = socket;
        this.id = id;
        this.startTime = new Date();
        this.lastUpdateTime = new Date();
    }
}

const clients = [] as ServerWebSocket<unknown>[];
const servers = [] as ServerInfo[];
const joiningClients = new Map<number, ServerWebSocket<unknown>>();
const lastTickMap = new Map();

let clientId = 0;

const corsHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET,OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
};

const server = Bun.serve({
    fetch(req, server) {
        const { pathname } = new URL(req.url);
        if (req.method === "OPTIONS") {
            return new Response(null, { status: 204, headers: corsHeaders });
        }
        // upgrade the request to a WebSocket
        if (server.upgrade(req)) {
            return; // do not return a Response
        }
        return new Response("Upgrade failed", { status: 500, headers: corsHeaders });
    },
    websocket: {
        open(ws) {
            console.log("New client");
            clients.push(ws);
        },
        close(ws, code, message) {
            clients.splice(clients.indexOf(ws), 1);
            const serverIdx = servers.findIndex((x) => x.socket == ws);
            if (serverIdx !== -1) {
                servers[serverIdx].lastUpdateTime = new Date();
                servers.splice(serverIdx, 1);
            }
        },
        message(conn, msg) {
            lastTickMap.set(conn, Date.now());
            let conts = JSON.parse(msg as string);
            console.log(`Received ${conts.type}`);
            if (conts.type == "serverInfo") {
                let serverInfo = new ServerInfo(
                    conn,
                    conts.id
                );
                if (servers.findIndex((x) => x.id === serverInfo.id) == -1) {
                    servers.push(serverInfo);
                } else {
                    let serverIndex = servers.findIndex((x) => x.id === serverInfo.id);
                    if (serverIndex != -1) {
                        servers[serverIndex] = serverInfo;
                    }
                }
            }
            if (conts.type == "connect") {
                let serverInfo = servers.find((x) => x.id == conts.id);
                if (serverInfo != null) {
                    let cid = clientId++;
                    joiningClients.set(cid, conn);
                    serverInfo.socket.send(
                        JSON.stringify({
                            type: "connect",
                            sdp: conts.sdp,
                            clientId: cid,
                            isPrivate: false,
                        })
                    );
                } else {
                    conn.send(
                        JSON.stringify({
                            type: "connectFailed",
                            reason: "Server not found",
                        })
                    );
                }
            }
            if (conts.type == "connectResponse") {
                let client = joiningClients.get(conts.clientId);
                if (client != null) {
                    let success = conts.success;
                    if (!success) {
                        client.send(
                            JSON.stringify({
                                type: "connectFailed",
                                reason: conts.reason,
                            })
                        );
                    } else {
                        client.send(
                            JSON.stringify({
                                type: "connectResponse",
                                sdp: conts.sdp,
                            })
                        );
                    }
                    joiningClients.delete(conts.clientId);
                }
            }
            if (conts.type == "serverList") {
                conn.send(
                    JSON.stringify({
                        type: "serverList",
                        servers: servers,
                    })
                );
            }
        },
    },
    port: 8080,
});

setInterval(() => {
    try {
        let curTimestamp = Date.now();
        for (const [conn, lastTime] of lastTickMap) {
            if (curTimestamp - lastTime > 30000) {
                try {
                    // conn.close();
                } catch (e2) {
                    console.log(e2);
                }
                lastTickMap.delete(conn);
            }
        }
        let toRemove = [];
        for (const server of servers) {
            if (server.socket.readyState >= 2) {
                toRemove.push(server);
            }
        }
        for (const server of toRemove) {
            console.log("Purging server " + server.id);
            server.lastUpdateTime = new Date();
            servers.splice(servers.indexOf(server), 1);
        }
    } catch (e) {
        console.log(e);
    }
}, 30000);

console.log("Server started");

process.on("uncaughtException", (err) => {
    console.error(err, "Uncaught Exception thrown");
});
