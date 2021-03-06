/*
 * Copyright (c) 2005-2006 Rincon Research Corporation
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * - Redistributions of source code must retain the above copyright
 *   notice, this list of conditions and the following disclaimer.
 * - Redistributions in binary form must reproduce the above copyright
 *   notice, this list of conditions and the following disclaimer in the
 *   documentation and/or other materials provided with the
 *   distribution.
 * - Neither the name of the Rincon Research Corporation nor the names of
 *   its contributors may be used to endorse or promote products derived
 *   from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE
 * RINCON RESEARCH OR ITS CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
 * OF THE POSSIBILITY OF SUCH DAMAGE
 */

/**
 * Fills in the network ID byte for outgoing packets for compatibility with
 * other 6LowPAN networks.  Filters incoming packets that are not
 * TinyOS network compatible.  Provides the 6LowpanSnoop interface to
 * sniff for packets that were not originated from TinyOS.
 *
 * @author David Moss
 */

#include "CC2420.h"
#include "Ieee154.h"

module CC2420TinyosNetworkP @safe() {
  provides {
    interface Resource[uint8_t client];

    interface Send as BareSend;
    interface Receive as BareReceive;

    interface Send as ActiveSend;
    interface Receive as ActiveReceive;
  }
  
  uses {
    interface Send as SubSend;
    interface Receive as SubReceive;
    interface CC2420Packet;
    interface CC2420PacketBody;
    interface ResourceQueue as Queue;

    interface CC2420Config;
  }
}

implementation {

  enum {
    OWNER_NONE = 0xff,
    TINYOS_N_NETWORKS = uniqueCount(RADIO_SEND_RESOURCE),
  } state;

  norace uint8_t resource_owner = OWNER_NONE, next_owner;

  command error_t ActiveSend.send(message_t* msg, uint8_t len) {
    call CC2420Packet.setNetwork(msg, TINYOS_6LOWPAN_NETWORK_ID);
    return call SubSend.send(msg, len);
  }

  command error_t ActiveSend.cancel(message_t* msg) {
    return call SubSend.cancel(msg);
  }

  command uint8_t ActiveSend.maxPayloadLength() {
    return call SubSend.maxPayloadLength();
  }

  command void* ActiveSend.getPayload(message_t* msg, uint8_t len) {
    if (len <= call ActiveSend.maxPayloadLength()) {
      return msg->data;
    } else {
      return NULL;
    }
  }

  /***************** Send Commands ****************/
  command error_t BareSend.send(message_t* msg, uint8_t len) {
    return call SubSend.send(msg, len - AM_OVERHEAD);
  }

  command error_t BareSend.cancel(message_t* msg) {
    return call SubSend.cancel(msg);
  }

  command uint8_t BareSend.maxPayloadLength() {
    return call SubSend.maxPayloadLength() + AM_OVERHEAD;
  }

  command void* BareSend.getPayload(message_t* msg, uint8_t len) {
#ifndef TFRAMES_ENABLED                      
    cc2420_header_t *hdr = call CC2420PacketBody.getHeader(msg);
    return &hdr->network;
#else
    // you really can't use BareSend with TFRAMES
#error "BareSend is not supported with TFRAMES: only the ActiveMessage layer is supported"
#endif
  }
  
  /***************** SubSend Events *****************/
  event void SubSend.sendDone(message_t* msg, error_t error) {
    if (call CC2420Packet.getNetwork(msg) == TINYOS_6LOWPAN_NETWORK_ID) {
      signal ActiveSend.sendDone(msg, error);
    } else {
      signal BareSend.sendDone(msg, error);
    }
  }

  /***************** SubReceive Events ***************/
  event message_t *SubReceive.receive(message_t *msg, void *payload, uint8_t len) {
    
    // perform CRC check only if it is wanted
    if(call CC2420Config.getCRCCheck() >= 1){
      if(!(call CC2420PacketBody.getMetadata(msg))->crc) {
        return msg;
      }
    }
#ifndef TFRAMES_ENABLED
    if (call CC2420Packet.getNetwork(msg) == TINYOS_6LOWPAN_NETWORK_ID) {
      return signal ActiveReceive.receive(msg, payload, len);
    } else {
      cc2420_header_t *hdr = call CC2420PacketBody.getHeader(msg);
      return signal BareReceive.receive(msg, &hdr->network, len + AM_OVERHEAD);
    }
#else
    return signal ActiveReceive.receive(msg, payload, len);
#endif
  }

  /***************** Resource ****************/
  // SDH : 8-7-2009 : testing if there's more then one client allows
  // the compiler to eliminate most of the logic when there's only one
  // client.
  task void grantTask() {


    if (TINYOS_N_NETWORKS > 1) {
      if (resource_owner == OWNER_NONE && !(call Queue.isEmpty())) {
        resource_owner = call Queue.dequeue();

        if (resource_owner != OWNER_NONE) {
          signal Resource.granted[resource_owner]();
        }
      }
    } else {
      if (next_owner != resource_owner) {
        resource_owner = next_owner;
        signal Resource.granted[resource_owner]();
      }
    }
  }

  async command error_t Resource.request[uint8_t id]() {

    post grantTask();

    if (TINYOS_N_NETWORKS > 1) {

      return call Queue.enqueue(id);
    } else {
      if (id == resource_owner) {
        return EALREADY;
      } else {
        next_owner = id;
        return SUCCESS;
      }
    }
  }

  async command error_t Resource.immediateRequest[uint8_t id]() {
    if (resource_owner == id) return EALREADY;

    if (TINYOS_N_NETWORKS > 1) {
      if (resource_owner == OWNER_NONE && call Queue.isEmpty()) {
        resource_owner = id;
        return SUCCESS;
      }
      return FAIL;
    } else {
      resource_owner = id;
      return SUCCESS;
    }
  }
  async command error_t Resource.release[uint8_t id]() {
    if (TINYOS_N_NETWORKS > 1) {
      post grantTask();
    }
    resource_owner = OWNER_NONE;
    return SUCCESS;
  }
  async command bool Resource.isOwner[uint8_t id]() {
    return (id == resource_owner);
  }

  /***************** Defaults ****************/
  default event message_t *BareReceive.receive(message_t *msg, void *payload, uint8_t len) {
    return msg;
  }
  default event void BareSend.sendDone(message_t *msg, error_t error) {

  }
  default event message_t *ActiveReceive.receive(message_t *msg, void *payload, uint8_t len) {
    return msg;
  }
  default event void ActiveSend.sendDone(message_t *msg, error_t error) {

  }
  default event void Resource.granted[uint8_t client]() {
    call Resource.release[client]();
  }


	event void CC2420Config.syncDone(error_t error){
		// TODO Auto-generated method stub
	}
}
