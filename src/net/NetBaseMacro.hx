package net;

import net.BitStream.OutputBitStream;
import net.BitStream.InputBitStream;
import haxe.macro.Context;
import haxe.macro.Expr.Field;
import haxe.macro.Expr.Case;

class NetBaseMacro {
	static var netClassIds:Array<Int> = [];

	static public function countRPCFunctions(klass:haxe.macro.Type.ClassType):Int {
		if (klass == null)
			return 0;
		var count = klass.superClass != null ? countRPCFunctions(klass.superClass.t.get()) : 0;
		for (field in klass.fields.get()) {
			var meta = field.meta.get();
			if (meta != null && meta.length > 0 && meta[0].name == ':rpc') {
				switch (field.kind) {
					case FMethod(MethNormal):
						{
							count++;
						}
					default:
						{
							null;
						}
				}
			}
		}
		return count;
	}

	macro static public function build():Array<Field> {
		var fields = Context.getBuildFields();
		var currentClass = Context.getLocalClass().get();
		var className = currentClass.name;

		var classType = "none";

		if (netClassIds.length == 0) {
			for (i in 0...NetClassType.ClassCount)
				netClassIds.push(0);
		}

		var meta = currentClass.meta.get();

		var classTypeInt:Int = 0;
		var classIdValue = -1;

		for (m in meta) {
			if (m.name == ":netClass") {
				var netClassTypeExpr = m.params[0].expr;
				switch (netClassTypeExpr) {
					case EConst(CIdent(netClassTypeStr)):
						classType = netClassTypeStr;

						classTypeInt = switch (classType) {
							case "ClassNone": NetClassType.ClassNone;
							case "ClassObject": NetClassType.ClassObject;
							case "ClassDataBlock": NetClassType.ClassDataBlock;
							case "ClassEvent": NetClassType.ClassEvent;
							case "ClassConnection": NetClassType.ClassConnection;
							case _: NetClassType.ClassCount;
						};

						var netClassId = netClassIds[classTypeInt];
						netClassIds[classTypeInt]++;

						classIdValue = netClassId;

						@:privateAccess NetClassDBMacro.netClasses.push({
							klass: currentClass,
							classType: netClassTypeStr,
							classId: netClassId
						});

					case _:
						null;
				}
			}
		}

		var toOverride = false;
		if (currentClass.superClass != null) {
			for (field in currentClass.superClass.t.get().fields.get()) {
				if (field.name == "getClassName") {
					toOverride = true;
					break;
				}
			}
		}

		// add a getClassName
		var classNameStuff = toOverride ? (macro class {
			public override function getClassName() {
				return $v{className};
			}

			public override function getClassRep() {
				return @:privateAccess NetClassDB.classReps[$v{classTypeInt}].get($v{classIdValue});
			}
		}) : (macro class {
			public function getClassName() {
				return $v{className};
			}

			public function getClassRep() {
				return @:privateAccess NetClassDB.classReps[$v{classTypeInt}].get($v{classIdValue});
			}
		});

		fields = fields.concat(classNameStuff.fields);

		// alright for RPC events, thats only supported for NetObject and ClassConnection
		if (classTypeInt == NetClassType.ClassConnection || classTypeInt == NetClassType.ClassObject) {
			// go over all the fields with @:rpc meta

			var rpcFuncId = 0;
			var rpcFuncs = [];
			var fieldsToAdd = [];
			var parentRPCCount = currentClass.superClass != null ? countRPCFunctions(currentClass.superClass.t.get()) : 0;

			for (field in fields) {
				if (field.meta != null && field.meta.length > 0 && field.meta[0].name == ':rpc') {
					switch (field.kind) {
						case FFun(f):
							{
								var serializeFns = [];
								var deserializeFns = [];
								var callExprs = [];
								var directionParam = field.meta[0].params[0].expr;
								var guaranteeParam = field.meta[0].params[1].expr;
								var directionValue = "DirUnset";
								var guaranteeValue = "GuaranteedOrdered";
								switch (directionParam) {
									case EConst(CIdent(s)):
										directionValue = s;
									default:
										null;
								}
								switch (guaranteeParam) {
									case EConst(CIdent(s)):
										guaranteeValue = s;
									default:
										null;
								}
								// Gather the args
								for (arg in f.args) {
									var argName = arg.name;
									switch (arg.type) {
										case TPath({
											name: 'Int'
										}): {
											deserializeFns.push(macro var $argName = stream.readInt32());
											callExprs.push(macro $i{argName});
											serializeFns.push(macro stream.writeInt32($i{argName}));
										}

										case TPath({
											name: 'Bool'
										}): {
											deserializeFns.push(macro var $argName = stream.readFlag());
											callExprs.push(macro $i{argName});
											serializeFns.push(macro stream.writeFlag($i{argName}));
										}

										case TPath({
											name: 'Float'
										}): {
											deserializeFns.push(macro var $argName = stream.readFloat());
											callExprs.push(macro $i{argName});
											serializeFns.push(macro stream.writeFloat($i{argName}));
										}

										case TPath({
											name: 'String'
										}): {
											deserializeFns.push(macro var $argName = stream.readString());
											callExprs.push(macro $i{argName});
											serializeFns.push(macro stream.writeString($i{argName}));
										}

										case _: {}
									}
								}
								deserializeFns.push(macro {
									$i{field.name + "_impl"}($a{callExprs});
								});

								var funcSerializeBody = classTypeInt == NetClassType.ClassConnection ? (macro {
									var stream = new OutputBitStream();
									$b{serializeFns} var evt = new RPCEvent();
									evt.direction = $i{directionValue};
									evt.guarantee = $i{guaranteeValue};
									evt.funcId = $v{rpcFuncId + parentRPCCount};
									evt.classType = NetClassType.ClassConnection;
									evt.argData = stream.getBytes();
									postNetEvent(evt);
								}) : (macro {
									var stream = new OutputBitStream();
									$b{serializeFns} var evt = new NetObjectRPCEvent();
									evt.direction = $i{directionValue};
									evt.guarantee = $i{guaranteeValue};
									evt.destObject = this;
									evt.funcId = $v{rpcFuncId + parentRPCCount};
									evt.classType = NetClassType.ClassObject;
									evt.argData = stream.getBytes();
									postNetEvent(evt);
								});

								var oldBody = f.expr;

								rpcFuncs.push({
									deserialize: deserializeFns,
								});

								f.expr = macro $e{funcSerializeBody};

								var implField:Field = {
									name: field.name + "_impl",
									pos: Context.currentPos(),
									access: [APublic],
									kind: FFun({
										args: (f.args),
										expr: oldBody
									})
								};
								fieldsToAdd.push(implField);

								rpcFuncId++;
							}
						default:
							null;
					}
				}
			}

			var cases:Array<Case> = [];
			var funcImpls = [];
			for (i in 0...rpcFuncId) {
				var func = rpcFuncs[i];
				cases.push({
					values: [macro $v{i + parentRPCCount}],
					expr: macro {
						$b{func.deserialize}
					}
				});
			}

			toOverride = false;
			if (currentClass.superClass != null) {
				for (field in currentClass.superClass.t.get().fields.get()) {
					if (field.name == "performRPC") {
						toOverride = true;
						break;
					}
				}
			}

			var rpcInterpretClass = toOverride ? (macro class {
				public override function performRPC(funcId:Int, stream:InputBitStream) {
					super.performRPC(funcId, stream);
					$e{
						{
							expr: ESwitch(macro funcId, cases, null),
							pos: Context.currentPos()
						}
					}
				}
			}) : (macro class {
				public function performRPC(funcId:Int, stream:InputBitStream) {
					$e{
						{
							expr: ESwitch(macro funcId, cases, null),
							pos: Context.currentPos()
						}
					}
				}
			});
			fields = fields.concat(rpcInterpretClass.fields).concat(fieldsToAdd);
		}

		return fields;
	}
}
