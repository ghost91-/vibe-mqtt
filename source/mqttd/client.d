﻿/**
 *
 * /home/tomas/workspace/mqtt-d/source/mqttd/client.d
 *
 * Author:
 * Tomáš Chaloupka <chalucha@gmail.com>
 *
 * Copyright (c) 2015 Tomáš Chaloupka
 *
 * Boost Software License 1.0 (BSL-1.0)
 *
 * Permission is hereby granted, free of charge, to any person or organization obtaining a copy
 * of the software and accompanying documentation covered by this license (the "Software") to use,
 * reproduce, display, distribute, execute, and transmit the Software, and to prepare derivative
 * works of the Software, and to permit third-parties to whom the Software is furnished to do so,
 * all subject to the following:
 *
 * The copyright notices in the Software and this entire statement, including the above license
 * grant, this restriction and the following disclaimer, must be included in all copies of the Software,
 * in whole or in part, and all derivative works of the Software, unless such copies or derivative works
 * are solely in the form of machine-executable object code generated by a source language processor.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 * INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
 * PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR ANYONE
 * DISTRIBUTING THE SOFTWARE BE LIABLE FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT,
 * TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 */
module mqttd.client;

import mqttd.messages;
import mqttd.serialization;
import mqttd.traits;

import std.algorithm : any, map;
import std.array : array;
import std.datetime;
import std.exception;
debug import std.stdio;
import std.string : format, representation;
import std.traits;
import std.typecons : Flag, No, Yes;

import vibe.core.concurrency;
import vibe.core.log;
import vibe.core.net: TCPConnection;
import vibe.core.stream;
import vibe.core.sync;
import vibe.core.task;
import vibe.utils.array : FixedRingBuffer;

// constants
enum MQTT_MAX_PACKET_ID = ushort.max; /// maximal packet id (0..65536) - defined by MQTT protocol

// default settings
enum MQTT_DEFAULT_BROKER_PORT = 1883u; /// default mqtt broker port
enum MQTT_DEFAULT_BROKER_SSL_PORT = 8883u; /// default mqtt broker ssl port
enum MQTT_DEFAULT_SENDQUEUE_SIZE = 1000u; /// maximal number of packets stored in queue to send
enum MQTT_DEFAULT_INFLIGHTQUEUE_SIZE = 10u; /// maximal number of packets which can be processed at the same time
enum MQTT_DEFAULT_CLIENT_ID = "vibe-mqtt"; /// default client identifier
enum MQTT_DEFAULT_RETRY_DELAY = 10_000u; /// retry interval to resend publish (QoS 1 or 2), subscribe and unsubscribe messages [ms]
enum MQTT_DEFAULT_RETRY_ATTEMPTS = 3u; /// max publish, subscribe and unsubscribe retry for QoS Level 1 or 2

// aliases
alias SessionContainer = FixedRingBuffer!(MessageContext);

/// MqttClient settings
struct Settings
{
	string host = "127.0.0.1"; /// message broker address
	ushort port = MQTT_DEFAULT_BROKER_PORT; /// message broker port
	string clientId = MQTT_DEFAULT_CLIENT_ID; /// Client Id to identify within message broker (must be unique)
	string userName = null; /// optional user name to login with
	string password = null; /// user password
	int retryDelay = MQTT_DEFAULT_RETRY_DELAY; /// retry interval to resend publish QoS 1 and 2 messages [ms]
	int retryAttempts = MQTT_DEFAULT_RETRY_ATTEMPTS; /// how many times will client try to resend QoS1 and QoS2 messages
	bool cleanSession = true; /// clean client and server session state on connect
	size_t sendQueueSize = MQTT_DEFAULT_SENDQUEUE_SIZE; /// maximal number of packets stored in queue to send
	size_t inflightQueueSize = MQTT_DEFAULT_INFLIGHTQUEUE_SIZE; /// maximal number of packets which can be processed at the same time
	ushort keepAlive; /// The Keep Alive is a time interval [s] to send control packets to server. It's used to determine that the network and broker are working. If set to 0, no control packets are send automatically (default).
	ushort reconnect; /// Time interval [s] in which client tries to reconnect to broker if disconnected. If set to 0, auto reconnect is disabled (default)
}

/**
 * Packet ID generator
 * Holds the status of ID usage and generates the next ones.
 *
 * It's a thread safe singleton
 */
class PacketIdGenerator
{
private:
	this()
	{
		_event = createManualEvent();
		setUsed(0);
	}

	// TLS flag, each thread has its own
	static bool instantiated_;

	// "True" global
	__gshared PacketIdGenerator instance_;

	pragma(inline, true) auto getIdx(ushort id) { return id / (size_t.sizeof*8); }
	pragma(inline, true) auto getIdxValue(ushort id) { return cast(size_t)(1uL << (id % (size_t.sizeof*8))); }

	LocalManualEvent _event;
	ushort _packetId = 0u;
	size_t[(MQTT_MAX_PACKET_ID+1)/(size_t.sizeof*8)] _idUsage; //1024 * 64 = 65536 => id usage flags storage

public:

	/// Instance of Packet ID generator
	@property static PacketIdGenerator get() @trusted
	{
		// Since every thread has its own instantiated_ variable,
		// there is no need for synchronization here.
		if (!instantiated_)
		{
			synchronized (PacketIdGenerator.classinfo)
			{
				if (!instance_)
				{
					instance_ = new PacketIdGenerator();
				}
				instantiated_ = true;
			}
		}
		return instance_;
	}

@safe:

	/// Gets next packet id. If the session is full it won't return till there is free space again
	@property auto nextPacketId()
	out (result)
	{
		assert(result, "packet id can't be 0!");
		assert(_event);
	}
	body
	{
		do
		{
			if (!_idUsage[].any!(a => a != size_t.max)())
			{
				version (MqttDebug) logDiagnostic("MQTT all packet ids in use - waiting");
				this._event.wait();
				continue;
			}

			//packet id can't be 0!
			_packetId = cast(ushort)((_packetId % MQTT_MAX_PACKET_ID) != 0 ? _packetId + 1 : 1);
		}
		while (isUsed(_packetId));

		version (MqttDebug) if (_packetId == 1) logDiagnostic("ID Overflow");

		setUsed(_packetId);

		return _packetId;
	}

	/// Is packet id currently used?
	pragma(inline) auto isUsed(ushort id) { return (_idUsage[getIdx(id)] & getIdxValue(id)) == getIdxValue(id); }

	/// Sets packet id as used
	pragma(inline) void setUsed(ushort id)
	{
		assert(!isUsed(id));
		assert(_event);

		_idUsage[getIdx(id)] |= getIdxValue(id);
		version (unittest) {} //HACK: For some reason unittest will segfault when emiting
		else _event.emit();
	}

	/// Sets packet id as unused
	pragma(inline) void setUnused(ushort id)
	{
		assert(id != 0);
		assert(isUsed(id));
		assert(_event);

		_idUsage[getIdx(id)] ^= getIdxValue(id);

		version (unittest) {} //HACK: For some reason unittest will segfault when emiting
		else _event.emit();
	}
}

unittest
{
	auto gen = PacketIdGenerator.get;
	assert(gen.getIdx(1) == 0);
	assert(gen.getIdx(64) == 1);
	assert(gen.getIdxValue(1) == gen.getIdxValue(65));
	assert(gen.getIdxValue(63) == 0x8000000000000000);
	assert(gen.getIdx(128) == 2);
	gen.setUsed(1);
	assert(gen.isUsed(1));
	gen.setUsed(64);
	assert(gen.isUsed(64));
	gen.setUnused(64);
	assert(!gen.isUsed(64));
	assert(gen.isUsed(1));
	gen.setUnused(1);

	foreach(i; 1..size_t.sizeof*8) gen.setUsed(cast(ushort)i);
	assert(gen._idUsage[0] == size_t.max);
}

/// MQTT packet state
enum PacketState
{
	queuedQos0, /// QOS = 0, Publish message queued
	queuedQos1, /// QOS = 1, Publish message queued
	queuedQos2, /// QOS = 2, Publish message queued

	waitForPuback, /// QOS = 1, PUBLISH sent, wait for PUBACK
	waitForPubrec, /// QOS = 2, PUBLISH sent, wait for PUBREC
	waitForPubrel, /// QOS = 2, PUBREC sent, wait for PUBREL
	waitForPubcomp, /// QOS = 2, PUBREL sent, wait for PUBCOMP
}

/// Origin of the stored packet
enum PacketOrigin
{
	client, /// originated from this client
	broker /// originated from broker
}

/// Context for MQTT packet stored in Session
private @safe struct MessageContext
{
	~this()
	{
		decRef();
	}

	this(Publish message, PacketState state, PacketOrigin origin = PacketOrigin.client)
	{
		assert(refcount is null);
		refcount = new int(1);

		this.timestamp = Clock.currTime;
		this.state = state;
		this.origin = origin;
		this.message = message;
		if (origin == PacketOrigin.client && state != PacketState.queuedQos0)
			this.message.packetId = PacketIdGenerator.get.nextPacketId();
	}

	this (this)
	{
		if (refcount !is null) *refcount += 1;
	}

	PacketState state; /// message state
	uint attempt; /// Attempt (for retry)
	SysTime timestamp; /// Timestamp (for retry)
	PacketOrigin origin; /// message origin
	Publish message; /// message itself

	alias message this;

private:
	int* refcount;

	void decRef()
	{
		if (refcount !is null)
		{
			if ((*refcount -= 1) == 0)
			{
				refcount = null;
				if (this.origin == PacketOrigin.client && this.packetId)
					PacketIdGenerator.get.setUnused(this.packetId);
			}
		}
	}
}

/// Queue storage helper for session
private @safe struct SessionQueue(Flag!"send" send)
{
	this(Settings settings)
	{
		_event = createManualEvent();

		static if (send) _packets = SessionContainer(settings.sendQueueSize);
		else _packets = SessionContainer(settings.inflightQueueSize);
	}

	@disable this();
	@disable this(this) {}

	/**
	 * Adds packet to Session
	 * If the session is full the call will be blocked until there is space again.
	 * Also if there is no free packetId to use, it will be blocked until it is.
	 *
	 * Params:
	 * 		packet = packet to be sent (can be Publish, Subscribe or Unsubscribe)
	 * 		state = initial packet state
	 * 		origin = origin of the packet (session stores control packets from broker too)
	 *
	 * Returns:
	 * 		Assigned packetId (0 if QoS0 is set). If message originates from broker, it keeps the original..
	 */
	ushort add(Publish packet, PacketState state, PacketOrigin origin = PacketOrigin.client)
	{
		return add(MessageContext(packet, state, origin));
	}

	/// ditto
	ushort add(MessageContext ctx)
	in
	{
		assert(ctx.packetId || ctx.state == PacketState.queuedQos0, "PacketId must be set");
		static if (send) assert(ctx.origin == PacketOrigin.client, "Only client messages can be added to send queue");

		with (PacketState)
		{
			final switch (ctx.state)
			{
				case queuedQos0:
				case queuedQos1:
				case queuedQos2:
					static if (!send) assert(0, "Invalid packet state");
					else break;
				case waitForPuback:
				case waitForPubcomp:
				case waitForPubrec:
				case waitForPubrel:
					static if (send) assert(0, "Invalid packet state");
					else break;
			}
		}
	}
	body
	{
		while (_packets.full)
		{
			static if (send)
			{
				if (ctx.state == PacketState.queuedQos0)
				{
					version (MqttDebug) logDebug("MQTT SendQueueFull - dropping QoS0 publish msg");
					return cast(ushort)0;
				}
				else
				{
					version (MqttDebug)
					{
						logDebug("MQTT SendQueueFull ([%s] %s) - waiting", ctx.packetId, ctx.state);
						scope (exit) logDebug("MQTT SendQueueFull after wait ([%s] %s)", ctx.packetId, ctx.state);
					}
					_event.wait();
				}
			}
			else
			{
				version (MqttDebug)
				{
					logDebug("MQTT InflightQueueFull ([%s] %s) - waiting", ctx.packetId, ctx.state);
					scope (exit) logDebug("MQTT InflightQueueFull after wait ([%s] %s)", ctx.packetId, ctx.state);
				}
				_event.wait();
			}
		}

		static if (send) assert(!_packets.full, format("SEND %s", ctx));
		else assert(!_packets.full, format("WAIT %s", ctx));

		_packets.put(ctx);
		_event.emit();

		return ctx.packetId;
	}

	/// Waits until the session state is changed
	auto wait()
	{
		return _event.wait();
	}

	/// Waits until the session state is changed or timeout is reached
	auto wait(Duration timeout)
	{
		return _event.wait(timeout, _event.emitCount);
	}

	/// Manually emit session state change to all listeners
	auto emit()
	{
		return _event.emit();
	}

	/// Removes the stored PacketContext
	void removeAt(size_t idx)
	{
		assert(idx < this.length);

		_packets.removeAt(_packets[idx..idx+1]);
		_event.emit();
	}

	/// Finds package context stored in session
	auto canFind(ushort packetId, out size_t idx, PacketState[] state...)
	{
		import alg = std.algorithm : canFind;
		foreach (i, ref c; _packets)
		{
			if (c.packetId == packetId && (!state.length || alg.canFind!(a => a == c.state)(state)))
			{
				idx = i;
				return true;
			}
		}

		return false;
	}

nothrow:

	ref MessageContext opIndex(size_t idx) @nogc pure
	{
		assert(idx < this.length);
		return _packets[idx];
	}

	@property ref MessageContext front() @nogc pure
	{
		return _packets.front();
	}

	void popFront()
	{
		assert(!_packets.empty);
		_packets.popFront();
		_event.emit();
	}

	@property bool empty() const @nogc pure
	{
		return _packets.empty;
	}

	@property bool full() const @nogc pure
	{
		return _packets.full;
	}

	/// Number of packets to process
	@property auto length() const @nogc pure
	{
		return _packets.length;
	}

	/// Clears cached messages
	void clear()
	{
		_packets.clear();
		_event.emit();
	}

private:
	LocalManualEvent _event;
	SessionContainer _packets;
}

/// MQTT session status holder
private @safe struct Session
{
	alias InflightQueue = SessionQueue!(No.send);
	alias SendQueue = SessionQueue!(Yes.send);

	this(Settings settings)
	{
		_inflightQueue = InflightQueue(settings);
		_sendQueue = SendQueue(settings);
	}

nothrow:

	@disable this(this) {}

	@property auto ref inflightQueue()
	{
		return _inflightQueue;
	}

	@property auto ref sendQueue()
	{
		return _sendQueue;
	}

	void clear()
	{
		this._inflightQueue.clear();
		this._sendQueue.clear();
	}

private:
	/// Packets to handle
	InflightQueue _inflightQueue;
	SendQueue _sendQueue;
}

unittest
{
	auto s = Session(Settings());

	auto pub = Publish();
	pub.header.qos = QoSLevel.QoS1;
	auto id = s.sendQueue.add(pub, PacketState.queuedQos1);

	assert(s.sendQueue.length == 1);

	size_t idx;
	assert(id != 0);
	assert(s.sendQueue.canFind(id, idx));
	assert(idx == 0);
	assert(s.sendQueue.length == 1);

	auto ctx = s.sendQueue[idx];

	assert(ctx.state == PacketState.queuedQos1);
	assert(ctx.attempt == 0);
	assert(ctx.message != Publish.init);
	assert(ctx.timestamp != SysTime.init);

	s.sendQueue.removeAt(idx);
	assert(s.sendQueue.length == 0);
}

/// MQTT Client implementation
@safe class MqttClient
{
	import std.array : Appender;
	import vibe.core.core : createTimer, setTimer, Timer;

	this(Settings settings)
	{
		import std.socket : Socket;

		_readMutex = new RecursiveTaskMutex();
		_writeMutex = new RecursiveTaskMutex();

		_settings = settings;
		if (_settings.clientId.length == 0) // set clientId if not provided
			_settings.clientId = Socket.hostName;

		_readBuffer.capacity = 4 * 1024;
		_session = Session(settings);
		_conAckTimer = createTimer(
			() @safe nothrow
			{
				logWarn("MQTT ConAck not received, disconnecting");
				this.disconnect();
			});
	}

	final
	{
		/// Connects to the specified broker and sends it the Connect packet
		void connect() @safe nothrow
		in { assert(!this.connected); }
		body
		{
			import vibe.core.core: runTask;
			import vibe.core.net: connectTCP;

			//Workaround for older vibe-core
			static if (!__traits(compiles, () nothrow { _conAckTimer.pending; } ))
			{
				bool pending;
				try pending = _conAckTimer.pending; catch (Exception) assert(false);
			}
			else auto pending = _conAckTimer.pending;

			if (pending)
			{
				version(MqttDebug) logDebug("MQTT Broker already Connecting");
				return;
			}

			//cleanup before reconnects
			_readBuffer.clear();
			if (_settings.cleanSession ) _session.clear();
			_onDisconnectCalled = false;

			try
			{
				_con = connectTCP(_settings.host, _settings.port);
				_listener = runTask(&listener);
				_dispatcher = runTask(&dispatcher);

				version(MqttDebug) logDebug("MQTT Broker Connecting");

				auto con = Connect();
				con.clientIdentifier = _settings.clientId;
				con.flags.cleanSession = _settings.cleanSession;
				con.keepAlive = cast(ushort)((_settings.keepAlive * 3) / 2);
				if (_settings.userName.length > 0)
				{
					con.flags.userName = true;
					con.userName = _settings.userName;
					if (_settings.password.length > 0)
					{
						con.flags.password = true;
						con.password = _settings.password;
					}
				}

				this.send(con);
				_conAckTimer.rearm(5.seconds);
			}
			catch (Exception ex)
			{
				() @trusted {logError("MQTT Error connecting to the broker: %s", ex);}();
				callOnDisconnect();
			}
		}

		/// Sends Disconnect packet to the broker and closes the underlying connection
		void disconnect() nothrow
		{
			if (this.connected)
			{
				version(MqttDebug) logDebug("MQTT Disconnecting from Broker");

				this.send(Disconnect());
				try
				{
					auto wlock = scopedMutexLock(_writeMutex);
					auto rlock = scopedMutexLock(_readMutex);
					try _con.flush(); catch (Exception) {} // acquires writer
					try _con.close(); catch (Exception) {} // acquires reader + writer
				}
				catch (Exception ex) {}

				_session.inflightQueue.emit();
				_session.sendQueue.emit();

				if(Task.getThis !is _listener)
					try _listener.join; catch (Exception) {}
			}
			else version(MqttDebug) logDebug("MQTT Already Disconnected from Broker");
		}

		/**
		 * Return true, if client is in a connected state
		 */
		@property bool connected() const nothrow
		{
			// not nothrow in older vibe-core
			try return _con && _con.connected; catch (Exception) return false;
		}

		/**
		 * Publishes the message on the specified topic
		 *
		 * Params:
		 *     topic = Topic to send message to
		 *     payload = Content of the message
		 *     qos = Required QoSLevel to handle message (default is QoSLevel.AtMostOnce)
		 *     retain = If true, the server must store the message so that it can be delivered to future subscribers
		 *
		 */
		void publish(T)(in string topic, in T payload, QoSLevel qos = QoSLevel.QoS0, bool retain = false)
			if (isSomeString!T || (isArray!T && is(ForeachType!T : ubyte)))
		{
			auto pub = Publish();
			pub.header.qos = qos;
			pub.header.retain = retain;
			pub.topic = topic;
			static if (isSomeString!T) pub.payload = payload.representation.dup;
			else pub.payload = payload.dup;

			//TODO: Maybe send QoS0 directly? Use settings parameter for it?
			_session.sendQueue.add(pub, qos == QoSLevel.QoS0 ?
				PacketState.queuedQos0 :
				(qos == QoSLevel.QoS1 ? PacketState.queuedQos1 : PacketState.queuedQos2));
		}

		/**
		 * Subscribes to the specified topics
		 *
		 * Params:
		 *      topics = Array of topic filters to subscribe to
		 *      qos = This gives the maximum QoS level at which the Server can send Application Messages to the Client.
		 *
		 */
		void subscribe(const string[] topics, QoSLevel qos = QoSLevel.QoS0)
		{
			auto sub = Subscribe();
			sub.packetId = _subId = PacketIdGenerator.get.nextPacketId();
			sub.topics = topics.map!(a => Topic(a, qos)).array;

			if (this.send(sub))
			{
				_subAckTimer = setTimer(dur!"msecs"(1_000),
					() @safe nothrow
					{
						logError("MQTT Server didn't respond with SUBACK - disconnecting");
						this.disconnect();
					});
			}
		}

		/**
		 * Unsubscribes from the specified topics
		 *
		 * Params:
		 *      topics = Array of topic filters to unsubscribe from
		 *
		 */
		void unsubscribe(const string[] topics...)
		{
			auto unsub = Unsubscribe();
			unsub.packetId = _unsubId = PacketIdGenerator.get.nextPacketId();
			unsub.topics = topics.dup;

			if (this.send(unsub))
			{
				_unsubAckTimer = setTimer(dur!"msecs"(1_000),
					() @safe nothrow
					{
						logError("MQTT Server didn't respond with UNSUBACK - disconnecting");
						this.disconnect();
					});
			}
		}
	}

	/// Response to connection request
	void onConnAck(ConnAck packet)
	{
		version(MqttDebug) logDebug("MQTT onConnAck - %s", packet);

		if(packet.returnCode == ConnectReturnCode.ConnectionAccepted)
		{
			version(MqttDebug) logDebug("MQTT Connection accepted");
			_conAckTimer.stop();
			if (_settings.keepAlive)
			{
				_pingReqTimer = setTimer(dur!"seconds"(_settings.keepAlive),
					() @safe nothrow
					{
						if (this.send(PingReq()))
						{
							//workaround for older vibe-core
							static if (!__traits(compiles, () nothrow { _pingRespTimer && _pingRespTimer.pending; }))
							{
								try if (_pingRespTimer && _pingRespTimer.pending) return;
								catch (Exception ex) {}
							}
							else if (_pingRespTimer && _pingRespTimer.pending) return;

							auto timeout = () @safe nothrow
							{
								logError("MQTT no PINGRESP received - disconnecting");
								this.disconnect();
							};

							static if (!__traits(compiles, () nothrow { setTimer(() @safe nothrow {}); }))
							{
								try _pingRespTimer = setTimer(dur!"seconds"(10), timeout, false);
								catch (Exception ex) logError("MQTT failed to set PINGRESP timeout: " ~ ex.msg);
							}
							else _pingRespTimer = setTimer(dur!"seconds"(10), timeout, false);
						}
					}, true);
			}
			_session.sendQueue.emit();
		}
		else throw new Exception(format("Connection refused: %s", packet.returnCode));
	}

	/// Response to PingReq
	void onPingResp(PingResp packet)
	{
		version(MqttDebug) logDebug("MQTT Received PINGRESP - %s", packet);

		if (_pingRespTimer && _pingRespTimer.pending) _pingRespTimer.stop;
	}

	// QoS1 handling

	/// Publish request acknowledged - QoS1
	void onPubAck(PubAck packet)
	{
		size_t idx;
		immutable found = _session.inflightQueue.canFind(packet.packetId, idx, PacketState.waitForPuback);

		if (found)
		{
			version(MqttDebug) logDebug("MQTT Received PUBACK - %s", packet);
			//treat the PUBLISH Packet as “unacknowledged” until corresponding PUBACK received
			_session.inflightQueue.removeAt(idx);
		}
		else logWarn("MQTT Received PUBACK with unknown ID - %s", packet);
	}

	// QoS2 handling - S:Publish, R: PubRec, S: PubRel, R: PubComp

	/// Publish request acknowledged - QoS2
	void onPubRec(PubRec packet)
	{
		size_t idx;
		immutable found = _session.inflightQueue.canFind(packet.packetId, idx,
			PacketState.waitForPubrec, PacketState.waitForPubcomp); // Both states to handle possible resends of unanswered PubRec packets

		if (found) { version(MqttDebug) logDebug("MQTT Received PUBREC - %s", packet); }
		else logWarn("MQTT Received PUBREC with unknown ID - %s", packet);

		//MUST send a PUBREL packet when it receives a PUBREC packet from the receiver.
		this.send(PubRel(packet.packetId)); //send directly to avoid lock on filled sendQueue

		if (found)
		{
			_session.inflightQueue[idx].state = PacketState.waitForPubcomp;
			_session.inflightQueue.emit();
		}
	}

	/// Confirmation that message was succesfully delivered (Sender side)
	void onPubComp(PubComp packet)
	{
		size_t idx;
		immutable found = _session.inflightQueue.canFind(packet.packetId, idx, PacketState.waitForPubcomp);

		if (found)
		{
			version(MqttDebug) logDebug("MQTT Received PUBCOMP - %s", packet);
			//treat the PUBREL packet as “unacknowledged” until it has received the corresponding PUBCOMP packet from the receiver.
			_session.inflightQueue.removeAt(idx);
		}
		else logWarn("MQTT Received PUBCOMP with unknown ID - %s", packet);
	}

	void onPubRel(PubRel packet)
	{
		size_t idx;
		immutable found = _session.inflightQueue.canFind(packet.packetId, idx, PacketState.waitForPubrel);

		if (found)
		{
			version(MqttDebug) logDebug("MQTT Received PUBREL - %s", packet);
			_session.inflightQueue.removeAt(idx);
		}
		else logWarn("MQTT Received PUBREL with unknown ID - %s", packet);

		//MUST respond to a PUBREL packet by sending a PUBCOMP packet containing the same Packet Identifier as the PUBREL.
		this.send(PubComp(packet.packetId)); //send directly to avoid lock on filled sendQueue
	}

	/// Message was received from broker
	void onPublish(Publish packet)
	{
		version(MqttDebug) logDebug("MQTT Received PUBLISH - %s", packet);

		if (packet.header.qos == QoSLevel.QoS1)
		{
			//MUST respond with a PUBACK Packet containing the Packet Identifier from the incoming PUBLISH Packet
			this.send(PubAck(packet.packetId));
		}
		else if (packet.header.qos == QoSLevel.QoS2)
		{
			//MUST respond with a PUBREC containing the Packet Identifier from the incoming PUBLISH Packet, having accepted ownership of the Application Message.
			this.send(PubRec(packet.packetId));
			_session.inflightQueue.add(packet, PacketState.waitForPubrel, PacketOrigin.broker);
		}
	}

	/// Message was succesfully delivered to broker
	void onSubAck(SubAck packet)
	{
		if (packet.packetId == _subId)
		{
			assert(_subId != 0);
			version(MqttDebug) logDebug("MQTT Received SUBACK - %s", packet);
			_subAckTimer.stop();
			PacketIdGenerator.get.setUnused(_subId);
			_subId = 0;
		}
		else logWarn("MQTT Received SUBACK with unknown ID - %s", packet);
	}

	/// Confirmation that unsubscribe request was successfully delivered to broker
	void onUnsubAck(UnsubAck packet)
	{
		if (packet.packetId == _unsubId)
		{
			assert(_unsubId != 0);
			version(MqttDebug) logDebug("MQTT Received UNSUBACK - %s", packet);
			_unsubAckTimer.stop();
			PacketIdGenerator.get.setUnused(_unsubId);
			_unsubId = 0;
		}
		else logWarn("MQTT Received UNSUBACK with unknown ID - %s", packet);
	}

	/// Client was disconnected from broker
	void onDisconnect() nothrow
	{
		version (MqttDebug) logDebug("MQTT onDisconnect, connected: %s", this.connected);

		if (this.connected)
		{
			try
			{
				auto rlock = scopedMutexLock(_readMutex);
				auto wlock = scopedMutexLock(_writeMutex);
				_con.close(); // acquires reader + writer
			}
			catch (Exception) {}
		}

		_session.inflightQueue.emit();
		_session.sendQueue.emit();

		//workaround older vibe-core
		static if (!__traits(compiles, _pingReqTimer && _pingReqTimer.pending))
		{
			try
			{
				if (_pingReqTimer && _pingReqTimer.pending) _pingReqTimer.stop();
				if (_pingRespTimer && _pingRespTimer.pending) _pingRespTimer.stop();
			}
			catch (Exception) {}
		}
		else
		{
			if (_pingReqTimer && _pingReqTimer.pending) _pingReqTimer.stop();
			if (_pingRespTimer && _pingRespTimer.pending) _pingRespTimer.stop();
		}
		if (_settings.reconnect)
		{
			auto recon = () @safe nothrow
				{
					logDiagnostic("MQTT reconnecting");
					this.connect();
				};

			static if (!__traits(compiles, () nothrow { setTimer(() @safe nothrow {}); }))
			{
				try _reconnectTimer = setTimer(dur!"seconds"(_settings.reconnect), recon, false);
				catch (Exception ex) logError("MQTT failed to set reconnect: " ~ ex.msg);
			}
			else _reconnectTimer = setTimer(dur!"seconds"(_settings.reconnect), recon, false);
		}
	}

private:
	Settings _settings;
	TCPConnection _con;
	Session _session;
	Task _listener, _dispatcher;
	Serializer!(Appender!(ubyte[])) _sendBuffer;
	FixedRingBuffer!ubyte _readBuffer;
	ubyte[] _packetBuffer;
	bool _onDisconnectCalled;
	Timer _conAckTimer, _subAckTimer, _unsubAckTimer, _pingReqTimer, _pingRespTimer, _reconnectTimer;
	ushort _subId, _unsubId;
	RecursiveTaskMutex _readMutex, _writeMutex;

final:

	/// Processes data in read buffer. If whole packet is presented, it delegates it to handler
	void proccessData(in ubyte[] data)
	{
		import mqttd.serialization;
		import std.range;

		version(MqttDebug) logTrace("MQTT IN: %(%.02x %)", data);

		if (_readBuffer.freeSpace < data.length) // ensure all fits to the buffer
			_readBuffer.capacity = _readBuffer.capacity + data.length;
		_readBuffer.put(data);

		while (_readBuffer.length > 0)
		{
			// try read packet header
			FixedHeader header = _readBuffer[0]; // type + flags

			// try read remaining length
			uint pos;
			uint multiplier = 1;
			ubyte digit;
			do
			{
				if (++pos >= _readBuffer.length) return; // not enough data
				digit = _readBuffer[pos];
				header.length += ((digit & 127) * multiplier);
				multiplier *= 128;
				if (multiplier > 128*128*128) throw new PacketFormatException("Malformed remaining length");
			} while ((digit & 128) != 0);

			if (_readBuffer.length < header.length + pos + 1) return; // not enough data

			// we've got the whole packet to handle
			_packetBuffer.length = 1 + pos + header.length; // packet type byte + remaining size bytes + remaining size
			_readBuffer.read(_packetBuffer); // read whole packet from read buffer

			with (PacketType)
			{
				final switch (header.type)
				{
					case CONNACK:
						onConnAck(_packetBuffer.deserialize!ConnAck());
						break;
					case PINGRESP:
						onPingResp(_packetBuffer.deserialize!PingResp());
						break;
					case PUBACK:
						onPubAck(_packetBuffer.deserialize!PubAck());
						break;
					case PUBREC:
						onPubRec(_packetBuffer.deserialize!PubRec());
						break;
					case PUBREL:
						onPubRel(_packetBuffer.deserialize!PubRel());
						break;
					case PUBCOMP:
						onPubComp(_packetBuffer.deserialize!PubComp());
						break;
					case PUBLISH:
						onPublish(_packetBuffer.deserialize!Publish());
						break;
					case SUBACK:
						onSubAck(_packetBuffer.deserialize!SubAck());
						break;
					case UNSUBACK:
						onUnsubAck(_packetBuffer.deserialize!UnsubAck());
						break;
					case CONNECT:
					case SUBSCRIBE:
					case UNSUBSCRIBE:
					case PINGREQ:
					case DISCONNECT:
					case RESERVED1:
					case RESERVED2:
						throw new Exception(format("Unexpected packet type '%s'", header.type));
				}
			}
		}
	}

	/// loop to receive packets
	void listener()
	in { assert(_con && _con.connected); }
	body
	{
		version (MqttDebug)
		{
			() @trusted { logDebug("MQTT Entering listening loop - TID:%s", thisTid); }();
			scope (exit) logDebug("MQTT Exiting listening loop");
		}

		auto buffer = new ubyte[4096];

		size_t size;
		while (_con.connected)
		{
			{
				auto lock = scopedMutexLock(_readMutex);
				if (!_con.waitForData(Duration.max)) break;
				size = cast(size_t)_con.leastSize;
				if (size == 0) break;
				if (size > buffer.length) size = buffer.length;
				_con.read(buffer[0..size]);
			}
			proccessData(buffer[0..size]);
		}

		callOnDisconnect();
	}

	/// loop to dispatch in session stored packets
	void dispatcher()
	in { assert(_con && _con.connected); }
	body
	{
		version (MqttDebug)
		{
			() @trusted { logDebug("MQTT Entering dispatch loop - TID:%s", thisTid); }();
			scope (exit) logDebug("MQTT Exiting dispatch loop");
		}

		while (true)
		{
			// wait for session state change
			_session.sendQueue.wait();

			if (!_con.connected) break;
			if (_conAckTimer.pending) continue; //wait for ConAck before sending any messages

			while (_session.sendQueue.length)
			{
				// wait for space in inflight queue
				while (_session.inflightQueue.full)
				{
					version (MqttDebug) logDebug("MQTT InflightQueue full, wait before sending next message");
					_session.inflightQueue.wait();
				}

				version (MqttDebug) logDebugV("MQTT Packets in session: send=%s, wait=%s", _session.sendQueue.length, _session.inflightQueue.length);
				auto ctx = _session.sendQueue.front;
				final switch (ctx.state)
				{
					// QoS0 handling - S:Publish, S:forget
					case PacketState.queuedQos0: // just send it
						//Sender request QoS0
						assert(ctx.origin == PacketOrigin.client);
						this.send(ctx.message);
						break;

					// QoS1 handling - S:Publish, R:PubAck
					case PacketState.queuedQos1:
						//Sender request QoS1
						//treat the Packet as “unacknowledged” until the corresponding PUBACK packet received
						assert(ctx.header.qos == QoSLevel.QoS1);
						assert(ctx.origin == PacketOrigin.client);
						this.send(ctx.message);
						ctx.state = PacketState.waitForPuback;
						_session.inflightQueue.add(ctx);
						break;

					// QoS2 handling - S:Publish, R: PubRec, S: PubRel, R: PubComp
					case PacketState.queuedQos2:
						//Sender request QoS2
						//treat the PUBLISH packet as “unacknowledged” until it has received the corresponding PUBREC packet from the receiver.
						assert(ctx.header.qos == QoSLevel.QoS2);
						assert(ctx.origin == PacketOrigin.client);
						this.send(ctx.message);
						ctx.state = PacketState.waitForPubrec;
						_session.inflightQueue.add(ctx);
						break;

					case PacketState.waitForPuback:
					case PacketState.waitForPubrec:
					case PacketState.waitForPubcomp:
					case PacketState.waitForPubrel:
						assert(0, "Invalid state");
				}

				//remove from sendQueue
				_session.sendQueue.popFront;
			}
		}

		if (!_con.connected) callOnDisconnect();
	}

	auto send(T)(auto ref T msg) nothrow if (isMqttPacket!T)
	{
		static if (is (T == Publish))
		{
			version (MqttDebug)
			{
				static SysTime last;
				static size_t messages;

				try
				{
					if (last == SysTime.init) last = Clock.currTime;
					messages++;

					auto diff = Clock.currTime - last;
					if (diff.total!"msecs" >= 1_000)
					{
						logDiagnostic("MQTT %s messages/s", cast(double)(1_000 * messages)/diff.total!"msecs");
						messages = 0;
						last = Clock.currTime;
					}
				}
				catch (Exception) {}
			}
		}

		_sendBuffer.clear(); // clear to write new
		try _sendBuffer.serialize(msg); catch (Exception ex) { assert(false, ex.msg); }

		if (this.connected)
		{
			version(MqttDebug)
			{
				logDebug("MQTT OUT: %s", msg);
				logDebugV("MQTT OUT: %(%.02x %)", _sendBuffer.data);
			}
			try
			{
				auto lock = scopedMutexLock(_writeMutex);
				_con.write(_sendBuffer.data);
				return true;
			}
			catch (Exception)
			{
				static if (!is(T == Disconnect)) this.disconnect();
				return false;
			}
		}
		else return false;
	}

	auto callOnDisconnect() nothrow
	{
		if (!_onDisconnectCalled)
		{
			_onDisconnectCalled = true;
			onDisconnect();
		}
	}

	// workaround for older vibe-core
	static if (!__traits(compiles, scopedMutexLock))
	{
		import core.sync.mutex : Mutex;
		ScopedMutexLock scopedMutexLock(Mutex mutex, LockMode mode = LockMode.lock) @safe
		{
			return ScopedMutexLock(mutex, mode);
		}
	}
}
