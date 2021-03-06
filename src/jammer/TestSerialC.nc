// $Id: TestSerialC.nc,v 1.6 2007/09/13 23:10:21 scipio Exp $

/*									tab:4
 * "Copyright (c) 2000-2005 The Regents of the University  of California.  
 * All rights reserved.
 *
 * Permission to use, copy, modify, and distribute this software and its
 * documentation for any purpose, without fee, and without written agreement is
 * hereby granted, provided that the above copyright notice, the following
 * two paragraphs and the author appear in all copies of this software.
 * 
 * IN NO EVENT SHALL THE UNIVERSITY OF CALIFORNIA BE LIABLE TO ANY PARTY FOR
 * DIRECT, INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING OUT
 * OF THE USE OF THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF THE UNIVERSITY OF
 * CALIFORNIA HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 * 
 * THE UNIVERSITY OF CALIFORNIA SPECIFICALLY DISCLAIMS ANY WARRANTIES,
 * INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 * AND FITNESS FOR A PARTICULAR PURPOSE.  THE SOFTWARE PROVIDED HEREUNDER IS
 * ON AN "AS IS" BASIS, AND THE UNIVERSITY OF CALIFORNIA HAS NO OBLIGATION TO
 * PROVIDE MAINTENANCE, SUPPORT, UPDATES, ENHANCEMENTS, OR MODIFICATIONS."
 *
 * Copyright (c) 2002-2003 Intel Corporation
 * All rights reserved.
 *
 * This file is distributed under the terms in the attached INTEL-LICENSE     
 * file. If you do not find these files, copies can be found by writing to
 * Intel Research Berkeley, 2150 Shattuck Avenue, Suite 1300, Berkeley, CA, 
 * 94704.  Attention:  Intel License Inquiry.
 */

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

#include "Timer.h"
#include <printf.h>
module TestSerialC {
  uses {
    interface SplitControl as Control;
    interface Leds;
    interface Boot;
    interface Timer<TMilli> as MilliTimer;
    interface Packet;
    
    interface SplitControl as ControlRadio;
    
    interface JammingRadio;
    interface Timer<TMilli> as JammerTimerMajor;
    interface Timer<TMilli> as JammerTimerMinor;
    
    interface CC2420Config as Config;
  }
}
implementation {

  message_t packet;

  bool locked = FALSE;
  uint16_t counter = 0;
  uint16_t recv = 0;

  bool radioOn=FALSE;  
  uint16_t radioCn=0;
  
  bool jammingOn=FALSE;

  void task startRadio();
  void task stopRadio();

  event void Boot.booted() {
    call Control.start();
  }
  
  event void MilliTimer.fired() {
    post startRadio();
  }

  void task startRadio(){
	call ControlRadio.start();
  }

  void task stopRadio(){
	call ControlRadio.stop();
  }

  event void Control.startDone(error_t err) {
    if (err == SUCCESS) {
      call MilliTimer.startPeriodic(1000);
    }
  }
  event void Control.stopDone(error_t err) {}

  event void ControlRadio.startDone(error_t err) {
    if (err == SUCCESS) {
    	// at first disable AUTO CRC generation - this may help to 
    	// speed up jamming thus chip is not calculating CRC of packets
    	//call Config.setAutoCRC(FALSE);
    	//call Config.sync();
    	
//    	printf("rstart\n");
    	//call JammerTimerMajor.startPeriodic(15000);
    	call JammerTimerMinor.startPeriodic(5000);
    }
  }
  event void ControlRadio.stopDone(error_t err) {}

    event void JammerTimerMajor.fired(){
		jammingOn=!jammingOn;
		if (jammingOn){
			call JammerTimerMinor.startPeriodic(100);
		} else {
			call JammingRadio.setJamming(FALSE);
			call JammerTimerMinor.stop();
		}		
	}

	event void JammerTimerMinor.fired(){
//		printf("[s]\n");
		call JammingRadio.setJamming(TRUE);
//		printfflush();
	}

	event void Config.syncDone(error_t error){
		// TODO Auto-generated method stub
	}
}




