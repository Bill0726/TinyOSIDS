/**
 * Application to test that the TinyOS java toolchain can communicate
 * with motes over the serial port. 
 *
 *  @author Gilman Tolle
 *  @author Philip Levis
 *  
 *  @date   Aug 12 2005
 *
 **/

//#define TUARTSYNC 1

#include "Timer.h"
#include "TestSerial2.h"

// enable printf debug?
//#define TESTDEBUG

#ifdef TESTDEBUG 
#include "printf.h"
#endif
module TimeTestP {
  uses {
    interface SplitControl as Control;
    interface SplitControl as ControlRadio;
    interface Leds;
    interface Boot;
    interface Receive;
    interface AMSend;
    interface Timer<TMilli> as MilliTimer;
    interface Packet;

// my extension

    interface Receive as RadioCmdRecv;
    interface Receive as UartCmdRecv;

    interface AMSend as UartCmdAMSend;
    interface AMSend as RadioCmdAMSend;
    interface AMSend as TimeSyncReportAMSend;
    interface AMPacket as SerialAMPacket;

    interface Reset as Reset;

    interface Timer<TMilli> as AliveTimer;
    interface Timer<TMilli> as InitTimer;
    interface PacketAcknowledgements as Acks;
    
    interface GlobalUARTTime<TMilli> as GlobalTime;
    interface TimeUARTSyncInfo;
    interface StdControl as TimeUARTCtl;
  }
}
implementation {
  enum {
	RADIO_CYCLE=1
  };


  message_t packet;

  bool locked = FALSE;
  uint16_t counter = 0;
  uint16_t recv = 0;
  uint16_t radioRecv = 0;
  uint16_t radioSent = 0;

  bool sendIt=FALSE;

  bool radioOn=FALSE;  
  bool radioRealOn=FALSE;  
  uint16_t radioCn=0;
  uint16_t radioInitCn=0;

  uint8_t radioErrCn;
  uint8_t radioErr;			
  /**************** COMMANDS ****************/
  message_t cmdPkt;
  message_t cmdPktResponse;
  message_t cmdPktResponseRadio;
  uint16_t commandCounter=0;
  am_addr_t commandDest=0;
  bool commandRadio=FALSE;
  // base station address
  am_addr_t baseid = 1;
  bool cmdRadioBusy=FALSE;
  bool cmdUartBusy=FALSE;

  // message 2 send
  CommandMsg cmdMsgPayload;

  uint16_t cmdReceived=0;

  uint16_t aliveCounter=0;
  bool serialBusy=FALSE;
  
  // time sync
  message_t timeSyncResponseBuffer;
  timeSyncReport * timeSyncResponse;
  bool timeSyncUartBusy=FALSE;
  uint16_t timeSyncSendError=0;
  /********** Forward declarations **********/
  void CommandReceived(message_t * msg, void * payload, uint8_t len);
  void task sendCommandRadio();
  void task sendCommandACK();
  void task sendAlive();
  void task startRadio();
  void task stopRadio();
  void task sendTimeSyncReportMsg();

  /************** MAIN CODE BELOW ***********/
  void setAck(message_t *msg, bool status){
        if (status){
        call Acks.requestAck(msg);                                                                                                                                                                                              
    } else {
        call Acks.noAck(msg);
    }
  }

  event void Boot.booted() {
    // initialize radio 7 seconds after boot - proved to be good strategy
    // because with direct initialization without delay, some problems
    // occurred (reboots, freezes).
    call InitTimer.startOneShot(7000);
    // initialize serial communication right now
    // serial line works fine with direct initialization.
    call Control.start();
  }
 
  // Status sending - message and error statistics.
  // Should be fired every second.
  event void MilliTimer.fired() {
    counter++;
    if (locked) {
      return;
    }
    else {
      test_serial_msg_t* rcm = (test_serial_msg_t*)call Packet.getPayload(&packet, sizeof(test_serial_msg_t));
      if (rcm == NULL) {return;}
      if (call Packet.maxPayloadLength() < sizeof(test_serial_msg_t)) {
	return;
      }

      rcm->counter = counter;
      rcm->received = recv;
      rcm->radioOn = radioOn;
      rcm->radioCn = radioInitCn;
      rcm->radioOn |= radioRealOn << 1;
      rcm->radioSent = radioSent;
      rcm->radioRecv = radioRecv;
      rcm->radioErr = radioErr;
      rcm->radioErrCn = radioErrCn;

      if (call AMSend.send(AM_BROADCAST_ADDR, &packet, sizeof(test_serial_msg_t)) == SUCCESS) {
	locked = TRUE;
      }
    }
  }

  event message_t* Receive.receive(message_t* bufPtr, 
				   void* payload, uint8_t len) {
	recv+=1;
	return bufPtr;
   }

 event void AMSend.sendDone(message_t* bufPtr, error_t error) {
    if (&packet == bufPtr) {
      locked = FALSE;
    }
  }

////////////////////////////////////////////////////////////////
////////////  MY extensions ////////////////////////////////////
////////////////////////////////////////////////////////////////
    /************************ COMMAND RECEIVED ************************/
    void CommandReceived(message_t * msg, void * payload, uint8_t len) {
		CommandMsg * btrpkt = NULL;
		CommandMsg * btrpktresponse = NULL;
		if(len != sizeof(CommandMsg)) {
			// invalid length - cannot process
			return;
		}
	
		cmdReceived+=1;
		recv+=1;

		// get received message
		btrpkt = (CommandMsg * ) payload;
#ifdef TESTDEBUG		
		printf("cmdRec c:%d\n", btrpkt->command_code);
#endif		
		// get local message, prepare it
		//btrpktresponse = (CommandMsg * )(call UartCmdAMSend.getPayload(&cmdPktResponse, sizeof(CommandMsg)));
		btrpktresponse = (CommandMsg * )(&cmdMsgPayload);

		// set reply ID by default
		btrpktresponse->reply_on_command = btrpkt->command_code;
		btrpktresponse->reply_on_command_id = btrpkt->command_id;
		btrpktresponse->command_code = COMMAND_ACK;
		commandDest = baseid;

		// decision based on type of command
		switch(btrpkt->command_code) {
			case COMMAND_IDENTIFY : // send my identification. Perform as task
				call AliveTimer.startOneShot(10);
				break;

			// enable sending radio messages remotely
			case 30:
				sendIt=TRUE;
				post sendCommandACK();
			break;
			
			// disable sending radio messages remotely
			case 31:
				sendIt=FALSE;
				post sendCommandACK();
			break;

			// de-init radio remotely
			case 33:
				post stopRadio();	
			break;
			
			// init radio remotely
			case 34:
				post startRadio();
			break;
				
			case COMMAND_RESET : // perform hard HW reset with watchdog to be sure that node is clean
				btrpktresponse->command_code = COMMAND_ACK;
				aliveCounter=0;
				
				post sendCommandACK();
				break;

			// send response as fast as possible
			case COMMAND_PING:
				btrpktresponse->command_code = COMMAND_ACK;
				btrpktresponse->reply_on_command_id = COMMAND_PING;
				post sendCommandACK();
				break;
			
			// time synchronization report request, send time global right now to serial.
			// enables to calculate accuracy of UART time synchronization among other nodes
			// since every node in near range should process incoming message (this) in the
			// same time - radio broadcast advantage  
			case COMMAND_TIMESYNC_GETGLOBAL:
                #ifdef TESTDEBUG			    
			    printf("[!tget %d]\n", TOS_NODE_ID);			    
			    printfflush();
			    #endif
			    {
			     // get this time ASAP, important here is that every node should do this
			     // in the same time, approximately.
			     timestamp_t globalTime;
			     timestamp_t localTime = call GlobalTime.getLocalTime();
			     call GlobalTime.getGlobalTime(&globalTime);
			     
                 #ifdef TESTDEBUG			     
			     printf("[!2hasLoc %ld %ld]\n", localTime, globalTime);
                 printfflush();
                 #endif       
                           
			     // now prepare message body, extracting another statistics from
			     // component. It is not time critical now, every statistic is static
			     // and it is not needed to compute it. 
			     timeSyncResponse = (nx_struct timeSyncReport*) call TimeSyncReportAMSend.getPayload(&timeSyncResponseBuffer, sizeof(nx_struct timeSyncReport));
			     timeSyncResponse->localTime = localTime;
			     timeSyncResponse->globalTime = globalTime;
			     timeSyncResponse->hbeats = call TimeUARTSyncInfo.getHeartBeats();
			     timeSyncResponse->entries = call TimeUARTSyncInfo.getNumEntries();
			     timeSyncResponse->lastSync = call TimeUARTSyncInfo.getSyncPoint();
			     timeSyncResponse->offset = call TimeUARTSyncInfo.getOffset();
			     timeSyncResponse->skew = call TimeUARTSyncInfo.getSkew();
			     
			     #ifdef TESTDEBUG
			     printf("[!2msgPrepared]\n");
                 printfflush();
			     #endif
			     
			     // Body completed, send to server, by posting a task.
			     // Warning! this is weak point, tasks are maintained by scheduler,
			     // if some problems occur this would be needed to re-progam somehow.
			     // But if node is idle, it should be processed ASAP
			     // Global time is set above, to the message. So only time measurement
			     // of message arrival to server can be affected by posting this task.
			     post sendTimeSyncReportMsg();
			     }
				break;
			
			// broadcast time synchronization report request to radio - as described above. 
			// This message is supposed to be processed by nearby nodes in the same time.
			case COMMAND_TIMESYNC_GETGLOBAL_BCAST:
			    #ifdef TESTDEBUG
			    printf("[tsb %d]\n", TOS_NODE_ID);
			    #endif
			    
				commandDest = AM_BROADCAST_ADDR;
				btrpktresponse->command_code = COMMAND_TIMESYNC_GETGLOBAL;
				post sendCommandRadio();
				break;
			
			// start/stop status sending	
			case 40:
				// start or stop?
				if (btrpkt->command_data > 0){
					call MilliTimer.startPeriodic(btrpkt->command_data_next[0]);
				} else {
					call MilliTimer.stop();
				}			
			break;
		}

		return;
	}
  
  void task sendTimeSyncReportMsg(){
  	if (timeSyncUartBusy){
  		if (++timeSyncSendError > 4){
  		    call TimeSyncReportAMSend.cancel(&timeSyncResponseBuffer);
  		}
  		return;
  	}
  	
  	#ifdef TESTDEBUG
  	printf("[sendingReport]");
  	#endif
  	
  	timeSyncSendError=FALSE;
  	// set source node ID
  	call SerialAMPacket.setType(&timeSyncResponseBuffer, TOS_NODE_ID);
  	
  	// send to base directly
    // sometimes node refuses to send too large packet. it will always end with fail
    // depends of buffers size.
    if (call TimeSyncReportAMSend.send(TOS_NODE_ID, &timeSyncResponseBuffer, sizeof(nx_struct timeSyncReport)) == SUCCESS) {
        timeSyncUartBusy=TRUE;
        #ifdef TESTDEBUG
        printf("reportSent");
        #endif
    }
    else {
        dbg("Cannot send message");
        post sendTimeSyncReportMsg();
    }
    #ifdef TESTDEBUG
    printfflush();
    #endif
  } 
    
  event void TimeSyncReportAMSend.sendDone(message_t *bufPtr, error_t error){
	if (&timeSyncResponseBuffer==bufPtr){
		#ifdef TESTDEBUG
		printf("[ReportSentDone %d]", error);
		#endif
	    timeSyncUartBusy=FALSE;
	    if (error!=SUCCESS){
	        if (++timeSyncSendError > 4){
                call TimeSyncReportAMSend.cancel(&timeSyncResponseBuffer);
            }
	    } else {
	    	timeSyncSendError=FALSE;
	    }
	}
   }

  /**
   * Send defined command to radio
   */
  void task sendCommandRadio(){
	CommandMsg* btrpkt = NULL;
	if(!sendIt){
		return;
	}
	
	 if (cmdRadioBusy){
	 	#ifdef TESTDEBUG
	 	printf("[rbusy]");
	 	#endif
		post sendCommandRadio();
		return;
	 }

	btrpkt=(CommandMsg*)(call RadioCmdAMSend.getPayload(&cmdPktResponseRadio, 0));

	// copy data from command msg payload stored
	memcpy((void *)btrpkt, (void *)&cmdMsgPayload, sizeof(CommandMsg));

	// setup message with data
	btrpkt->command_id = counter;

	// disable ACKs
	setAck(&cmdPktResponseRadio, FALSE);

	// send to base directly
	// sometimes node refuses to send too large packet. it will always end with fail
	// depends of buffers size.
	if (call RadioCmdAMSend.send(AM_BROADCAST_ADDR, &cmdPktResponseRadio, sizeof(CommandMsg)) == SUCCESS) {
	    cmdRadioBusy=TRUE;
	    radioSent+=1;
	    
	    #ifdef TESTDEBUG
	    printf("[rsent:%d]", radioSent);
	    #endif
	}
	else {
		post sendCommandRadio();
	}
  }


  /**
   * Send ACK command
   * packet is prepared before calling this
   */
   void task sendCommandACK(){
	CommandMsg* btrpkt = NULL;
	if (cmdUartBusy){
		post sendCommandACK();
		return;
	}

    btrpkt=(CommandMsg*)(call UartCmdAMSend.getPayload(&cmdPktResponse, 0));

    // copy data from command msg payload stored
    memcpy((void *)btrpkt, (void *)&cmdMsgPayload, sizeof(CommandMsg));

    // setup message with data
    btrpkt->command_id = counter;

    // send to base directly
    // sometimes node refuses to send too large packet. it will always end with fail
    // depends of buffers size.
    if (call UartCmdAMSend.send(commandDest, &cmdPktResponse, sizeof(CommandMsg)) == SUCCESS) {
		cmdUartBusy = TRUE;
    }
    else {
		dbg("Cannot send message");
		post sendCommandACK();
    }
  }

  /**
   * Command received on uart
   */
  event message_t* UartCmdRecv.receive(message_t* bufPtr, void* payload, uint8_t len) {
  	#ifdef TESTDEBUG
    printf("[rU]");
    printfflush();
    #endif
    
	CommandReceived(bufPtr, payload, len);
	return bufPtr;
  }

  /**
   * Command received on radio
   */ 
  event message_t* RadioCmdRecv.receive(message_t* bufPtr, void* payload, uint8_t len) {
	radioRecv+=1;
	
	#ifdef TESTDEBUG
	printf("[rRRRRR!! %d]", radioRecv);
	printfflush();
	#endif
	
	CommandReceived(bufPtr, payload, len);

	return bufPtr;
  }
  
  /**
   * Radio command send done
   */
  event void RadioCmdAMSend.sendDone(message_t *msg, error_t error){
	radioSent+=1;
	radioErr = (uint16_t) error;
	
	#ifdef TESTDEBUG
	printf("[sendDone %d]", error);
	#endif
	
	if (&cmdPktResponseRadio==msg){
		#ifdef TESTDEBUG
		printf("[pktresposne %d]", error);
		#endif
		
		cmdRadioBusy=FALSE;
		if (error!=SUCCESS){
			radioErrCn+=1;
		}
	}
  }

  /**
   * Uart command send done
   */
  event void UartCmdAMSend.sendDone(message_t* bufPtr, error_t error) {
	if (&cmdPktResponse==bufPtr || &cmdPkt==bufPtr){
		cmdUartBusy=FALSE;
		if (error!=SUCCESS){
			post sendCommandACK();
		}
	}
  }

  event void AliveTimer.fired(){
	// first 10 messages are sent quickly
	if (aliveCounter>10){
		call AliveTimer.startPeriodic(1000);
	}
	
	post sendAlive();
  }

  // sends alive packet to application to know that node is OK
  void task sendAlive(){
	CommandMsg * btrpkt = NULL;
	if (cmdUartBusy) {
		dbg("Cannot send indentify message");
		post sendAlive();
		return;
	}
	
	atomic {
		btrpkt = (CommandMsg* ) (call UartCmdAMSend.getPayload(&cmdPkt, sizeof(CommandMsg)));
		// only one report here, yet
		btrpkt->command_id = aliveCounter;
		btrpkt->reply_on_command = COMMAND_IDENTIFY;
		btrpkt->command_code = COMMAND_ACK;
		btrpkt->command_version = 1;
		btrpkt->command_data = 0xffff;
		btrpkt->command_data_next[0]=1;
		btrpkt->command_data_next[1] = TOS_NODE_ID;
	
	// congestion information
	// first 8 bites = free slots in radio queue
	// next 8 bites = free slots in serial queue
	btrpkt->command_data_next[2] = cmdReceived;
	btrpkt->command_data_next[3] = 0;
	
		if(call UartCmdAMSend.send(TOS_NODE_ID, &cmdPkt, sizeof(CommandMsg)) == SUCCESS) {
			aliveCounter+=1;
			cmdUartBusy = TRUE;
		}
		else {
			post sendAlive();
			dbg("Cannot send identify message");
		}
	}
  }

//////////////////////////////////////////////////////
// Radio & serial initialization
//////////////////////////////////////////////////////
  void task startRadio(){
	call ControlRadio.start();
  }

  void task stopRadio(){
	call ControlRadio.stop();
  }

  event void InitTimer.fired(){
        radioOn=!radioOn;
        radioInitCn+=1;
	 	
	if (radioOn){
		#ifdef TESTDEBUG
		printf("radiostart");
		printfflush();
		#endif
		
		post startRadio();
	} else {
		#ifdef TESTDEBUG
		printf("radiostop");
		printfflush();
		#endif
		
		post stopRadio();
	}
  }

///////////////////////////////////////////////////////////////////////
//// RADIO INITIALIZATION /////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////

  /** 
   * Serial initialized event
   */ 
  event void Control.startDone(error_t err) {
    if (err == SUCCESS) {
    	// initialize time sync component - when serial is started.
    	// it works over UART so this is right place to do initialization.
        call TimeUARTCtl.start();
        
        #ifdef TESTDEBUG
        printf("[BOOTED]");
        printfflush();
        #endif
        
      // serial init successful, start sending status reports 
      //call MilliTimer.startPeriodic(20);
    }
  }
  event void Control.stopDone(error_t err) {}

  /**
   * Radio initialized event
   */
  event void ControlRadio.startDone(error_t err) {
    if (err == SUCCESS || err==EALREADY) {
        radioRealOn=TRUE;
        // radio initialized  
		if (radioInitCn<RADIO_CYCLE){
			// re-init radio
			#ifdef TESTDEBUG
			printf("[rcycle<]\n");
			#endif
			
			call InitTimer.startOneShot(5000);
		} else {
			// radio init finished
			sendIt = TRUE;
			
			#ifdef TESTDEBUG
			printf("[rinitOK]\n");
			#endif
			
			// alive timer is disabled during time sync test.
			// we don't want another UART activity to block 
			// time sync report since it is time sensitive.
			//call AliveTimer.startPeriodic(1000);
		}
    } else {
    	#ifdef TESTDEBUG
    	printf("[rinitErr: %d]\n", err);
    	#endif
    	
	    radioRealOn=FALSE;
	    call InitTimer.startOneShot(5000);
    }
    
    #ifdef TESTDEBUG
    printfflush();
    #endif
  }

  event void ControlRadio.stopDone(error_t err) {
	radioRealOn=FALSE;
	
	#ifdef TESTDEBUG
	printf("[rStopDone %d]", err);
	printfflush();
	#endif
	
	if (radioInitCn<RADIO_CYCLE){
		call InitTimer.startOneShot(5000);
	}
	}
}
