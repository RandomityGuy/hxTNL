import net.NetInterface;
import h3d.Vector;
import examplenet.TestConnection;
import examplenet.Player;
import examplenet.Building;

@:publicFields
class TestGame {
	var players:Array<Player> = [];
	var buildings:Array<Building> = [];
	var isServer:Bool;
	var serverPlayer:Player;
	var clientPlayer:Player;
	var lastTime:Float;
	var scene:h2d.Scene;

	static var connectionToServer:TestConnection;

	public static var instance:TestGame;

	public function new(server:Bool, scene:h2d.Scene) {
		this.scene = scene;
		isServer = server;
		lastTime = haxe.Timer.stamp();
		if (isServer) {
			for (i in 0...50) {
				var b = new Building();
				b.addToGame(this);
			}
			for (i in 0...15) {
				var p = new Player();
				@:privateAccess p.playerType = TypeAI;
				p.addToGame(this);
			}
			serverPlayer = new Player();
			@:privateAccess serverPlayer.playerType = TypeMyClient;
			serverPlayer.addToGame(this);
		}
	}

	public function update(t:Float) {
		for (p in players)
			p.update(t);
		lastTime += t;
	}

	public function moveMyPlayerTo(pos:Vector) {
		if (isServer)
			serverPlayer.serverSetPosition(serverPlayer.renderPos, pos, 0, 0.2);
		else {
			if (clientPlayer != null)
				clientPlayer.rpcPlayerWillMove("Whee! Foo!");
			connectionToServer.rpcSetPlayerPos(pos.x, pos.y);
		}
	}
}
