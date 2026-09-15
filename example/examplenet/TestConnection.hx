package examplenet;

import net.GhostConnection;
import net.NetClassDB;
import net.BitStream.InputBitStream;
import net.BitStream.OutputBitStream;
import net.NetClassType;
import h3d.Vector;
import net.RPCEvent;

@:netClass(ClassConnection)
@:publicFields
class TestConnection extends GhostConnection {
	var myPlayer:Player;

	public override function isDataToTransmit():Bool {
		return true;
	}

	public override function onConnectionEstablished() {
		super.onConnectionEstablished();

		if (!isHost) {
			setGhostFrom(false);
			setGhostTo(true);
			TestGame.connectionToServer = this;
			trace("Connected to server");
		} else {
			var p = new Player();
			myPlayer = p;
			myPlayer.addToGame(TestGame.instance);
			setScopeObject(myPlayer);
			setGhostFrom(true);
			setGhostTo(false);
			activateGhosting();
			trace("Client connected");
		}
	}

	@:rpc(DirAny, GuaranteedOrdered)
	public function rpcGotPlayerPos(b1:Bool, b2:Bool, string:String, x:Float, y:Float) {
		trace('Server acknowledged position update - ${b1} ${b2} ${string} ${x} ${y}');
	}

	@:rpc(DirClientToServer, GuaranteedOrdered)
	public function rpcSetPlayerPos(x:Float, y:Float) {
		trace('Received new position (${x}, ${y}) from client');
		myPlayer.serverSetPosition(myPlayer.renderPos, new Vector(x, y, 0), 0, 0.2);
		rpcGotPlayerPos(true, false, "Hello World!!", x, y);
	}
}
