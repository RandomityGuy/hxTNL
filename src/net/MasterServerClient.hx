package net;

import haxe.Json;
import haxe.net.WebSocket;

typedef RemoteServerInfo = {
	id:String,
}

class MasterServerClient {
	public static var instance:MasterServerClient;

	var ws:WebSocket;
	var serverListCb:Array<RemoteServerInfo>->Void;

	var open = false;

	static var wsToken:Int = 0;

	#if hl
	var wsThread:sys.thread.Thread;

	static var responses:sys.thread.Deque<() -> Void> = new sys.thread.Deque<() -> Void>();

	var toSend:sys.thread.Deque<String> = new sys.thread.Deque<String>();
	var stopping:Bool = false;
	var stopMutex:sys.thread.Mutex = new sys.thread.Mutex();
	#end

	public function new(serverIp:String, onOpenFunc:() -> Void, onErrorFunc:() -> Void) {
		#if hl
		wsThread = sys.thread.Thread.create(() -> {
			hl.Gc.enable(false);
			hl.Gc.blocking(true); // Wtf is this shit
		#end
			wsToken++;

			var myToken = wsToken;

			ws = WebSocket.create(serverIp);
			#if hl
			hl.Gc.enable(true);
			hl.Gc.blocking(false);
			#end
			ws.onopen = () -> {
				open = true;
				#if hl
				responses.add(() -> onOpenFunc());
				#end
				#if js
				onOpenFunc();
				#end
			}
			ws.onmessageString = (m) -> {
				#if hl
				responses.add(() -> handleMessage(m));
				#end
				#if js
				handleMessage(m);
				#end
			}
			ws.onerror = (m) -> {
				#if hl
				if (onErrorFunc != null)
					responses.add(() -> {
						onErrorFunc();
					});
				#end
				#if js
				if (onErrorFunc != null)
					onErrorFunc();
				#end
				#if hl
				stopMutex.acquire();
				#end
				if (myToken == wsToken) {
					open = false;
					ws = null;
					instance = null;
				}
				#if hl
				stopping = true;
				stopMutex.release();
				if (myToken == wsToken) {
					wsThread = null;
				}
				#end
			}
			ws.onclose = (?e) -> {
				#if hl
				stopMutex.acquire();
				#end
				if (myToken == wsToken) {
					open = false;
					ws = null;
					instance = null;
				}
				#if hl
				stopping = true;
				stopMutex.release();
				if (myToken == wsToken) {
					wsThread = null;
				}
				#end
			}
			#if hl
			while (true) {
				stopMutex.acquire();
				if (stopping)
					break;
				while (true) {
					var s = toSend.pop(false);
					if (s == null)
						break;
					#if hl
					hl.Gc.blocking(true);
					#end
					ws.sendString(s);
					#if hl
					hl.Gc.blocking(false);
					#end
				}

				#if hl
				hl.Gc.blocking(true);
				#end
				ws.process();
				#if hl
				hl.Gc.blocking(false);
				#end
				stopMutex.release();
				Sys.sleep(0.1);
			}
			#end
		#if hl
		});
		#end
	}

	public static function process() {
		#if sys
		var resp = responses.pop(false);
		if (resp != null) {
			resp();
		}
		#end
	}

	public static function connectToMasterServer(serverIp:String, onConnect:() -> Void, onError:() -> Void = null) {
		if (instance == null)
			instance = new MasterServerClient(serverIp, onConnect, onError);
		else {
			if (instance.open)
				onConnect();
			else {
				if (instance != null && instance.ws != null)
					instance.ws.close();
				instance = new MasterServerClient(serverIp, onConnect, onError);
			}
		}
	}

	public static function disconnectFromMasterServer() {
		if (instance != null && instance.ws != null) {
			instance.ws.close();
			if (instance != null) {
				instance.open = false;
				instance.ws = null;
				instance = null;
			}
		}
	}

	function queueMessage(m:String) {
		#if hl
		toSend.add(m);
		#end
		#if js
		ws.sendString(m);
		#end
	}

	public function heartBeat() {
		queueMessage(Json.stringify({
			type: "heartbeat"
		}));
	}

	public function sendServerInfo(serverId:String) {
		queueMessage(Json.stringify({
			type: "serverInfo",
			id: serverId,
		}));
	}

	public function sendConnectToServer(serverId:String, sdp:String) {
		queueMessage(Json.stringify({
			type: "connect",
			id: serverId,
			sdp: sdp,
		}));
	}

	public function getServerList(serverListCb:Array<RemoteServerInfo>->Void) {
		this.serverListCb = serverListCb;
		queueMessage(Json.stringify({
			type: "serverList"
		}));
	}

	function handleMessage(message:String) {
		var conts = Json.parse(message);
		if (conts.type == "serverList") {
			if (serverListCb != null) {
				serverListCb(conts.servers);
			}
		}
		if (conts.type == "connect") {
			NetInterface.addConnectionFromSDP(conts.sdp, (sdpReply) -> {
				queueMessage(Json.stringify({
					success: true,
					type: "connectResponse",
					sdp: sdpReply,
					clientId: conts.clientId
				}));
			});
		}
		if (conts.type == "connectResponse") {
			var sdpObj = Json.parse(conts.sdp);
			if (NetInterface.pendingConnection != null) {
				trace("[Local] Got SDP Answer");
				NetInterface.pendingConnection.setRemoteDescription(sdpObj.sdp, "answer");
			}
		}
		if (conts.type == "connectFailed") {}
	}
}
