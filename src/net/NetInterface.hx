package net;

import net.BitStream.InputBitStream;
import haxe.io.BytesInput;
import haxe.io.Bytes;
import net.NetConnection;
import net.BitStream.OutputBitStream;
import net.MasterServerClient.RemoteServerInfo;
import haxe.Json;
import datachannel.RTCDataChannel;
import datachannel.RTCPeerConnection;

enum abstract PacketType(Int) from Int to Int {
	var ConnectRequest = 2;
	var ConnectReject = 3;
	var ConnectAccept = 4;
	var Disconnect = 5;
	var FirstValidInfoPacketId = 6;
}

class NetInterface {
	static var connections:Array<NetConnection> = [];
	static var pendingConnections:Array<NetConnection> = [];

	static var id:String;

	static var masterServerIp:String;
	public static var iceServers:Array<String>;
	public static var boundIp:String;

	public static var pendingConnection:NetConnection;

	static var lastTimeoutCheckTime = 0.0;

	static final ConnectRetryTime = 2.5;
	static final ConnectRetryCount = 4;
	static final TimeoutCheckInterval = 1.5;

	public static function setConfiguration(bindIp:String, iceServerList:Array<String>, masterIp:String) {
		masterServerIp = masterIp;
		iceServers = iceServerList;
		boundIp = bindIp;
	}

	public static function listen() {
		id = Uuid.v4();
		MasterServerClient.connectToMasterServer(masterServerIp, () -> {
			trace("Connected to master server");
			MasterServerClient.instance.sendServerInfo(id);
		}, () -> {});
	}

	public static function connect(id:String, netConnection:NetConnection) {
		MasterServerClient.connectToMasterServer(masterServerIp, () -> {
			var nc = netConnection;
			pendingConnection = nc;
			nc.onLocalDescription = (desc) -> {
				trace("[Local] Got SDP");
				MasterServerClient.instance.sendConnectToServer(id, Json.stringify({sdp: desc, type: "offer"}));
			}
			nc.initialize(false);
			pendingConnections.push(nc);
		});
	}

	public static function getServerList(serverListCb:Array<RemoteServerInfo>->Void) {
		MasterServerClient.connectToMasterServer(masterServerIp, () -> {
			MasterServerClient.instance.getServerList(serverListCb);
		});
	}

	public static function addConnectionFromSDP(sdp:String, sdpReply:String->Void) {
		var sdpObj = Json.parse(sdp);
		var nc = new NetConnection();
		nc.onLocalDescription = (desc) -> {
			trace("[Remote] Got SDP");
			sdpReply(Json.stringify({sdp: desc, type: "answer"}));
		}
		nc.initialize(true);
		nc.setRemoteDescription(sdpObj.sdp, "offer");
		pendingConnections.push(nc);
	}

	static function processPacket(conn:NetConnection, bytes:Bytes) {
		var firstByte = bytes.get(0);
		if ((firstByte & 0x80) > 0) { // protocol packet
			conn.readRawPacket(new InputBitStream(bytes));
		} else {
			var bi = new haxe.io.BytesInput(bytes);
			var packetType = bi.readByte();
			switch (packetType) {
				case ConnectRequest:
					handleConnectRequest(conn, bi);
				case ConnectReject:
					handleConnectReject(conn, bi);
				case ConnectAccept:
					handleConnectAccept(conn, bi);
				case Disconnect:
					handleDisconnect(conn, bi);
			}
		}
	}

	public static function processConnections() {
		var curTime = time();

		for (conn in connections)
			conn.checkPacketSend(false, curTime);

		if (curTime > lastTimeoutCheckTime + TimeoutCheckInterval) {
			var toRemove = [];
			for (conn in pendingConnections) {
				if (!conn.isHost) { // only clients send the connect request
					if (conn.connectionState == AwaitingConnectRequest) {
						conn.connectionState = AwaitingConnectResponse;
						sendConnectRequest(conn);
					}
					if (conn.connectionState == AwaitingConnectResponse) {
						if (curTime > conn.connectLastSendTime + ConnectRetryTime) {
							if (conn.connectSendCount > ConnectRetryCount) {
								conn.connectionState = ConnectTimedOut;
								conn.onConnectTerminated(TimedOut, "Timed out");
								toRemove.push(conn);
							} else {
								sendConnectRequest(conn); // try again!
							}
						}
					}
				}
			}
			for (conn in toRemove)
				pendingConnections.remove(conn);
			lastTimeoutCheckTime = curTime;

			toRemove.resize(0);
			for (conn in connections) {
				if (conn.checkTimeout(curTime)) {
					conn.connectionState = TimedOut;
					conn.onConnectionTerminated(TimedOut, "Timeout");
					toRemove.push(conn);
				}
			}
			for (conn in toRemove)
				connections.remove(conn);
		}
	}

	static function sendConnectRequest(conn:NetConnection) {
		var b = new haxe.io.BytesOutput();
		b.writeByte(ConnectRequest);
		b.writeInt32(conn.connectSequence);
		b.writeInt16(conn.getClassRep().getClassId());
		conn.writeConnectRequest(b);
		conn.connectSendCount += 1;
		conn.connectLastSendTime = time();
		conn.send(b.getBytes());
	}

	static function handleConnectRequest(conn:NetConnection, bi:BytesInput) {
		var connectSequence = bi.readInt32();
		var connClass = bi.readInt16();

		var connInst:NetConnection = cast NetClassDB.construct(connClass, ClassConnection);
		if (connInst == null)
			return; // failed
		conn.transferOwnership(connInst);

		var errStr = connInst.readConnectRequest(bi);
		if (errStr != null) {
			sendConnectReject(connInst, errStr);
			pendingConnections.remove(conn);
			return;
		}
		connInst.connectionState = Connected;
		connInst.connectSequence = connectSequence;
		sendConnectAccept(connInst);
		connections.push(connInst);
		pendingConnections.remove(conn);
		connInst.onConnectionEstablished();
	}

	static function sendConnectAccept(conn:NetConnection) {
		var b = new haxe.io.BytesOutput();
		b.writeByte(ConnectAccept);
		b.writeInt32(conn.connectSequence);
		conn.writeConnectAccept(b);
		conn.send(b.getBytes());
	}

	static function sendConnectReject(conn:NetConnection, err:String) {
		var b = new haxe.io.BytesOutput();
		b.writeByte(ConnectReject);
		b.writeByte(err.length);
		b.writeString(err);
		conn.send(b.getBytes());
	}

	static function handleConnectReject(conn:NetConnection, bi:BytesInput) {
		var reasonLen = bi.readByte();
		var reason = bi.readString(reasonLen);

		conn.connectionState = ConnectRejected;
		conn.onConnectionTerminated(RemoteRejectedConnection, reason);
		pendingConnections.remove(conn);
	}

	static function handleConnectAccept(conn:NetConnection, bi:BytesInput) {
		var seq = bi.readInt32();
		if (conn.connectSequence == seq) {
			var errStr = conn.readConnectAccept(bi);
			if (errStr != null) {
				sendConnectReject(conn, errStr);
				pendingConnections.remove(conn);
				return;
			}

			pendingConnections.remove(conn);
			conn.connectionState = Connected;
			conn.onConnectionEstablished();
			connections.push(conn);
		}
	}

	static function handleDisconnect(conn:NetConnection, bi:BytesInput) {
		var reasonLen = bi.readByte();
		var reason = bi.readString(reasonLen);

		conn.connectionState = Disconnected;
		conn.onConnectionTerminated(RemoteDisconnectPacket, reason);
		connections.remove(conn);
	}

	public static function time() {
		return haxe.Timer.stamp();
	}
}
