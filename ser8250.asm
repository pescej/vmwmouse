	page	,132
;-----------------------------Module-Header-----------------------------;
; Module Name:	SER8250.ASM
;
; Windows mouse driver data and initialization routines for using a
; 8250 based mouse for Windows
;
; Created: 21-Aug-1987
; Author:  Mr. Mouse [mickeym], Walt Moore [waltm], and a supporting
;	   cast of thousands
;
; Copyright (c) 1986,1987  Microsoft Corporation
;
; Exported Functions:
;	None
; Public Functions:
;	serial_enable
;	serial_disable
;	serial_search
; Public Data:
;	None
; General Description:
;	This module contains the functions to find, enable, disable,
;	and process interrupts for an 8250 based Mouse.
;-----------------------------------------------------------------------;

	title	8250 Serial Mouse Hardware Dependent Code

	.xlist
	include cmacros.inc
	include mouse.inc
	include ins8250.inc
	.list

	??_out	ser8250


	externNP hook_us_in		;Hook us into our interrupt
	externNP unhook_us		;Hook us out of our interrupt
	externNP enable_our_int 	;Enable us at the 8259



;	Definition of the bits of each 7-bit packet returned from
;	the serial mouse.  There will be three packets per mouse
;	event.

					;First packet
HIGH_X		equ	00000011b	;  D8:D7 of X delta (first packet)
HIGH_Y		equ	00001100b	;  D8:D7 of Y delta
B2_STAT 	equ	00010000b	;  Right button is down
B1_STAT 	equ	00100000b	;  Left  button is down
SYNC_BIT	equ	01000000b	;  Mark's first of three packets
LOW_X		equ	00111111b	;Second packet is X packet
LOW_Y		equ	00111111b	;Third	packet is Y packet (last)


P1_HIGH_X	equ	00000011b	;Current D8:D7 of X delta
P1_HIGH_Y	equ	00001100b	;Current D8:D7 of Y delta
P1_B2_STAT	equ	00010000b	;Current  right button status (1=down)
P1_B1_STAT	equ	00100000b	;Current  left	button status (1=down)
P1_OLD_B2_STAT	equ	01000000b	;Previous right button status (1=down)
P1_OLD_B1_STAT	equ	10000000b	;Previous left	button status (1=down)

	.errnz	P1_HIGH_X-HIGH_X	;These bits must be the same
	.errnz	P1_HIGH_Y-HIGH_Y	;  as in the first packet
	.errnz	P1_B2_STAT-B2_STAT
	.errnz	P1_B1_STAT-B1_STAT


NEED_PACKET_1	equ	-2		;Looking for sync   packet
NEED_PACKET_2	equ	-1		;Looking for second packet
NEED_PACKET_3	equ	0		;Looking for third  packet


BAUD_DIVISOR	equ	0096		;Divisor for 1200 baud


sBegin	Data

externB vector				;Vector # of mouse interrupt
externB mask_8259			;8259 interrupt enable mask
externB mouse_flags			;Various flags as follows
externW io_base 			;Mouse port base address
externW enable_proc			;Address of routine to	enable mouse
externW disable_proc			;Address of routine to disable mouse
externB device_int			;Start of mouse specific int handler
externW interrupt_rate			;Maximum interrupt rate of mouse
externD event_proc			;Mouse event procedure when enabled

sEnd	Data


sBegin	Code
assumes cs,Code
page

;	This is the start of the data which will be copied into
;	the device_int area reserved in the data segment.

SER_START	equ	this word

;--------------------------Interrupt-Routine----------------------------;
; serail_int - Mouse Interrupt Handler for an 8250 Serial Mouse
;
; This is the handler for the interrupt generated by the 8250 Serial
; mouse.  It will reside in the Data segment.
;
; Entry:
;	None
; Returns:
;	None
; Error Returns:
;	None
; Registers Preserved:
;	ALL
; Registers Destroyed:
;	None
; Calls:
;	event_proc if mouse event occured
; History:
;	Fri 21-Aug-1987 11:43:42 -by-  Walt Moore [waltm] & Mr. Mouse
;	Initial version
;-----------------------------------------------------------------------;

;------------------------------Pseudo-Code------------------------------;
; {
; }
;-----------------------------------------------------------------------;

	assumes cs,Code
	assumes ds,nothing
	assumes es,nothing
	assumes ss,nothing

SER_PROC_START	equ	$-SER_START	;Delta to this procedure
		.errnz	SER_PROC_START	;Must be first

serial_int	proc	far

	push	ax
	push	bx
	push	cx
	push	dx
	push	si
	push	di
	push	bp
	push	ds
	push	es
	mov	ax,_DATA
	mov	ds,ax
	assumes ds,Data

	mov	dx,io_base		;Port base address
	mov	cl,2			;Shifting by two a lot
	in	al,dx			;Get data
	shl	al,cl
	jnc	x_or_y			;If no sync bit, may be X or Y
	.errnz	SYNC_BIT-01000000b

	mov	ah,device_int[PACKET_1]
	shl	ah,cl			;Put old button state into AH[D7:D6]
	rol	ah,cl			;Put old button state into AH[D1:D0]
	shr	ax,cl			;Put old button state into AL[D7:D6]
	mov	device_int[PACKET_1],al

	.errnz	P1_B2_STAT-00010000b	;The bits must be this for the
	.errnz	P1_B1_STAT-00100000b	;  rotating to work
	.errnz	P1_OLD_B2_STAT-01000000b
	.errnz	P1_OLD_B1_STAT-10000000b

	mov	ax,NEED_PACKET_2 shl 8	;Show packet 2 needed, no event
	jmp	short set_next_packet


;	This packet is either an X or an Y packet.  If it is an
;	X packet, save it away and increment the packet count.
;	If it is a Y packet, then process all the rest of the
;	data (X delta and button deltas) and pass the event
;	on to Windows.
;
;	If PACKET_COUNT indicates that we should be looking for
;	a sync bit, then ignore this packet.

x_or_y:
	inc	bptr device_int[PACKET_COUNT]
	jg	packet_is_y		;0=>1, this is last packet
	mov	device_int[PACKET_2],al ;Assume we wanted to save it
	mov	al,0			;Show no event (preserve flags)
	jz	serial_eoi		;This was the correct packet
	jmp	short set_packet_1	;We were looking for sync packet
	.errnz	NEED_PACKET_1+2 	;Must be -2
	.errnz	NEED_PACKET_2+1 	;Must be -1
	.errnz	NEED_PACKET_3



;	This is the last packet.  Convert all the info into what
;	Windows needs and pass it off to it.  Both packets 2 and
;	3 have already been shifted left 2 bits.

packet_is_y:
	mov	dx,wptr device_int[PACKET_2]
	if2
	.errnz	PACKET_1-PACKET_2-1	;Want PACKET_1 in DH, PACKET_2 in DL
	endif
	shr	dx,cl			;Compute delta X and leave it in DL
	.errnz	LOW_X-00111111b
	.errnz	P1_HIGH_X-00000011b

	mov	ah,dh
	shr	ax,cl			;Compute delta Y and leave it in AL
	.errnz	LOW_Y-00111111b
	.errnz	P1_HIGH_Y-00001100b

	xor	bh,bh			;Get the button delta info
	mov	bl,ah
	mov	bl,bptr device_int[bx][STATE_XLATE]

	cbw				;Sign extend Y and place it in
	xchg	ax,cx			;  CX for Windows
	xchg	ax,dx			;Sign extend X and place it in
	cbw				;  BX for Windows
	xchg	ax,bx			;Hey, the button status is now in AX!

	mov	dx,bx			;Set movement bit if movement
	or	dx,cx
	neg	dx
	rcl	ax,1
	.errnz	SF_MOVEMENT-00000001b

set_packet_1:
	mov	ah,NEED_PACKET_1	;Show next packet must be sync packet

set_next_packet:
	mov	bptr device_int[PACKET_COUNT],ah

serial_eoi:
	xchg	al,ah
	mov	al,EOI
	out	ACK_PORT,al
	xchg	al,ah
	cbw				;MSB will always be zero for us
	or	ax,ax			;Only call out if something happened
	jz	ser8250_no_data
	mov	dx,NUMBER_BUTTONS
        xor     si,si 			;Zero out messageextrainfo for 3.1
        xor     di,di
	sti
	call	event_proc

ser8250_no_data:
	pop	es
	pop	ds
	pop	bp
	pop	di
	pop	si
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	iret

serial_int	endp

page

;	BIOS_PORT_INDEX is the location within the bios data area
;	where the serial port address was found.  If the mouse's
;	base port address is found in this table, the location
;	will be zeroed when enabled, and restored when disabled.

BIOS_PORT_INDEX equ	$-SER_START	;Delta to this byte
		dw	0		;Assume not in table



;	PACKET_2 will contain the second packet of three.  It will
;	contain the low 6-bits of the X delta.

PACKET_2	=	$-SER_START	;Delta to this byte
		db	0



;	PACKET_1 contains the contents of the first packet of the
;	three.	It will also contain the previous button state.

PACKET_1	equ	$-SER_START	;Delta to this byte
		db	0

;	PACKET_COUNT indicates which packet is expected next.  This
;	allows us to do a little error checking on the packets.


PACKET_COUNT	=	$-SER_START	;Delta to this byte
		db	0
page

;-----------------------------------------------------------------------;
; state_xlate
;
;	state_xlate is used to translate the current and previous
;	button state information into the values required by
;	Windows.  It is indexed as follows:
;
;	    pB1 pB2 cB1 cB2
;
;	     |	 |   |	 |
;	     |	 |   |	  --- 1 if button 2 is	down, 0 if button 2 is	up
;	     |	 |   |
;	     |	 |    ------- 1 if button 1 is	down, 0 if button 1 is	up
;	     |	 |
;	     |	  ----------- 1 if button 2 was down, 0 if button 2 was up
;	     |
;	      --------------- 1 if button 1 was down, 0 if button 1 was up
;
;	This table must be copied to the data segment along with the
;	interrupt handler.
;
;-----------------------------------------------------------------------;

STATE_XLATE	equ	$-SER_START	;delta to this table

	db	0			shr 1
	db	(SF_B2_DOWN)		shr 1
	db	(SF_B1_DOWN)		shr 1
	db	(SF_B1_DOWN+SF_B2_DOWN) shr 1

	db	(SF_B2_UP)		shr 1
	db	0			shr 1
	db	(SF_B2_UP+SF_B1_DOWN)	shr 1
	db	(SF_B1_DOWN)		shr 1

	db	(SF_B1_UP)		shr 1
	db	(SF_B2_DOWN+SF_B1_UP)	shr 1
	db	0			shr 1
	db	(SF_B2_DOWN)		shr 1

	db	(SF_B1_UP+SF_B2_UP)	shr 1
	db	(SF_B1_UP)		shr 1
	db	(SF_B2_UP)		shr 1
	db	0			shr 1

	.errnz	NUMBER_BUTTONS-2	;Won't work unless a two button mouse


SER_INT_LENGTH	= $-SER_START		;Length of code to copy
	.errnz	SER_INT_LENGTH gt MAX_INT_SIZE

display_int_size  %SER_INT_LENGTH
page

;---------------------------Private-Routine-----------------------------;
; serial_enable - Enable Serial Mouse
;
; The Serial mouse will be initialized, the interrupt vector hooked,
; the old interrupt mask saved, and our interrupt enabled at the 8259.
;
; Entry:
;	None
; Returns:
;	None
; Error Returns:
;	None
; Registers Preserved:
;	BP,DS
; Registers Destroyed:
;	AX,BX,CX,DX,SI,DI,ES,FLAGS
; Calls:
;	hook_us_in
;	enable_our_int
;	test_card
; History:
;	Fri 21-Aug-1987 11:43:42 -by-  Walt Moore [waltm] & Mr. Mouse
;	Initial version
;-----------------------------------------------------------------------;

;------------------------------Pseudo-Code------------------------------;
; {
; }
;-----------------------------------------------------------------------;

	assumes ds,Data
	assumes es,nothing
	assumes ss,nothing

		public	serial_enable	;Public for debugging
serial_enable	proc	near

	call	hook_us_in		;Hook us into the interrupt

;	It is possible that somebody unplugged the serial mouse
;	since we were last here.  Tough.  We'll ignore the error
;	for now.

	mov	di,io_base		;Initialize the serial mouse
	call	test_card


;	See if BIOS knows about this card.  If so, delete if from
;	the BIOS table so other applications will not try and use it.

	mov	ax,BIOSDataSeg
	mov	es,ax
	assumes es,BIOSDataSeg
	xor	ax,ax

	mov	wptr device_int[BIOS_PORT_INDEX],-1;port address not zeroed
	mov	bx,offset rs232_data	;Start of serial ports
	cmp	es:[bx],di
	je	zero_bios_port		;Match
	inc	bx
	inc	bx
	cmp	es:[bx],di
	jne	save_bios_addr		;No match

zero_bios_port:
	mov	es:[bx],ax		;Zero the port address
	xchg	ax,bx			;Set AX = address of match
	mov	wptr device_int[BIOS_PORT_INDEX],ax

save_bios_addr:
	mov	bptr device_int[PACKET_COUNT],NEED_PACKET_1

	call	enable_our_int		;Enable 8259 interrupts

	lea	dx,[di].ACE_IER 	;Enable interrupts at the 8250
	mov	al,ACE_ERBFI
	out	dx,al

	lea	dx,[di].ACE_MCR 	;Also have to raise ACE_OUT2
	io_delay			;  to get interrupts off the board
	in	al,dx
	or	al,ACE_OUT2
	io_delay
	out	dx,al

	ret

serial_enable	endp
page

;---------------------------Private-Routine-----------------------------;
; serial_disable - Disable Serial Mouse
;
; The interrupt vector will be restored, the old interrupt mask
; restored at the 8259.  If the old mask shows that the mouse was
; previously enabled, it will remain enabled, else we will disable
; interrupts at the mouse itself.
;
; Entry:
;	None
; Returns:
;	None
; Error Returns:
;	None
; Registers Preserved:
;	DS,BP
; Registers Destroyed:
;	AX,BX,CX,DX,SI,DI,ES,FLAGS
; Calls:
;	unhook_us
; History:
;	Fri 21-Aug-1987 11:43:42 -by-  Walt Moore [waltm] & Mr. Mouse
;	Initial version
;-----------------------------------------------------------------------;

;------------------------------Pseudo-Code------------------------------;
; {
; }
;-----------------------------------------------------------------------;

	assumes ds,Data
	assumes es,nothing
	assumes ss,nothing

		public	serial_disable	;Public for debugging
serial_disable	proc	near

	mov	di,io_base
	lea	dx,[di].ACE_IER 	;Disable interrupts at the 8250
	xor	al,al
	out	dx,al
	lea	dx,[di].ACE_MCR 	;Tri-state the serial board IRQ
	io_delay			;  by dropping ACE_OUT2
	in	al,dx
	and	al,not ACE_OUT2
	io_delay
	out	dx,al

	call	unhook_us		;Restore everything to what it was
	jnz	serial_restore_bios_data;IRQ was previously disabled

	mov	di,io_base
	lea	dx,[di].ACE_IER 	;Disable interrupts at the 8250
	mov	al,ACE_ERBFI
	out	dx,al
	lea	dx,[di].ACE_MCR 	;Also have to raise ACE_OUT2
	io_delay			;  to get interrupts off the board
	in	al,dx
	or	al,ACE_OUT2
	io_delay
	out	dx,al

serial_restore_bios_data:

;	See if BIOS knew about this card.  If so, restore the BIOS
;	table so other applications may use the port.

	mov	cx,wptr device_int[BIOS_PORT_INDEX]
	inc	cx			;-1 = port address not zeroed out
	jcxz	done_with_serial_disable
	dec	cx			;cx has offset in 40:
	mov	ax,BIOSDataSeg
	mov	es,ax
	assumes es,BIOSDataSeg
	xchg	bx,cx
	mov	es:[bx],di		;Restore port address

done_with_serial_disable:
	ret

serial_disable	endp
page

;-----------------------------------------------------------------------;
;	ser_parms is the table of serial ports to search fro when
;	looking for a mouse.  An installed mouse driver may have
;	already zeroed the port address in the ROM BIOS data area,
;	so we use this table.
;-----------------------------------------------------------------------;

ser_parms	label	word
					;Serial port 2 (COM2)
	dw	2F8h			;  io_base
	db	0Bh			;  Interrupt vector number
	db	11110111b		;  Interrupt request mask (IRQ 3)
					;Serial port 1 (COM1)
	dw	3F8h			;  io_base
	db	0Ch			;  Interrupt vector number
	db	11101111b		;  Interrupt request mask (IRQ 4)

	dw	0			;End of table


page

;---------------------------Public-Routine------------------------------;
; serial_search - Search for a Serial Mouse
;
; A search will be made for a serial mouse.
;
; Entry:
;	None
; Returns:
;	'C' set if found
;	  AX = address of interrupt routine if interrupt vector found
;	  SI = offset within the Code segment of the handler
; Error Returns:
;	'C' clear if not found
; Registers Preserved:
;	DS,BP
; Registers Destroyed:
;	AX,BX,DX,ES,FLAGS
; Calls:
;	test_card
; History:
;	Mon 24-Aug-1987 23:54:02 -by-  Walt Moore [waltm] & Mr. Mouse
;	Initial version
;-----------------------------------------------------------------------;

;------------------------------Pseudo-Code------------------------------;
; {
; }
;-----------------------------------------------------------------------;

	assumes cs,Code
	assumes ds,Data

		public	serial_search
serial_search	proc	near

	mov	si,CodeOFFSET ser_parms ;Table of possible serial cards

next_serial_port:
	lods	wptr cs:[si]		;Get next port address
	or	ax,ax			;If 0, then end of ports
	jz	no_serial_mouse 	;Return 'C' clear to show not found
	mov	io_base,ax
	lods	wptr cs:[si]
	mov	vector,al
	mov	mask_8259,ah
	call	test_card		;See if card is the mouse
	jc	next_serial_port	;Not the mouse, try next card

	mov	interrupt_rate,40
	mov	enable_proc,CodeOFFSET serial_enable
	mov	disable_proc,CodeOFFSET serial_disable
	mov	si,CodeOFFSET serial_int
	mov	cx,SER_INT_LENGTH
	stc				;'C' to show found
	ret

no_serial_mouse:
	mov	vector,-1		;We trashed this and must restore it
	ret				;'C' clear

serial_search	endp
page

;---------------------------Private-Routine-----------------------------;
; test_card - Test Serial Card For A Mouse
;
; The serial port will be programmed correctly for the mouse, and
; a test made to see if one is really attached.  If found, then the
; port is correctly programmed for the mouse.  If not found, the
; port will be restored.
;
; Interrupts for the port will be disabled at the 8259 prior to the
; search, and restored to their initial state afterwards.
;
; Entry:
;	None
; Returns:
;	'C' set if found
;	'C' clear if not found
; Error Returns:
;	None
; Registers Preserved:
;	SI,DS,BP
; Registers Destroyed:
;	AX,BX,CX,DX,DI,ES,FLAGS
; Calls:
;	test_loop
; History:
;	Mon 24-Aug-1987 23:54:02 -by-  Walt Moore [waltm] & Mr. Mouse
;	Initial version
;-----------------------------------------------------------------------;

;------------------------------Pseudo-Code------------------------------;
; {
; }
;-----------------------------------------------------------------------;

	assumes cs,Code
	assumes ds,Data

		public	test_card	;Public for debugging
test_card	proc	near

;	While futzing with the 8250, we'll disable interrupts
;	at the 8259.

	mov	ah,mask_8259		;Get our 8259 enable mask
	not	ah			;A 1 bit for our IRQ
	cli
	in	al,MASK_PORT		;Get current 8259 mask
	mov	bl,al
	or	al,ah
	out	MASK_PORT,al		;Disable mouse int
	sti

	and	bl,ah			;Isolate old IRQ bit, keep in BL

	mov	di,io_base		;Keep base address in DI
	lea	dx,[di].ACE_LCR 	;Save line control on stack
	in	al,dx
	push	ax

	mov	al,ACE_DLAB		;Access divisor latches
	io_delay
	out	dx,al

	lea	dx,[di].ACE_DLM 	;Save MSB divisor
	io_delay
	in	al,dx
	push	ax

	mov	al,high BAUD_DIVISOR	;Set MSB of our divisor
	io_delay
	out	dx,al

	lea	dx,[di].ACE_DLL 	;Save LSB divisor
	io_delay
	in	al,dx
	push	ax

	mov	al,low BAUD_DIVISOR	;Set LSB of our divisor
	io_delay
	out	dx,al

	lea	dx,[di].ACE_LCR 	;Line control port
	mov	al,ACE_7BW+ACE_1SB
	io_delay
	out	dx,al

	lea	dx,[di].ACE_IER 	;Interrupt enable port
	io_delay
	in	al,dx			;--> interrupt enable
	push	ax			;Save interrupt enable on stack

	xor	al,al			;Disable 8250 interrupts
	io_delay
	out	dx,al

	lea	dx,[di].ACE_LSR 	;Clear error flags
	io_delay
	in	al,dx

	lea	dx,[di].ACE_MCR 	;Save modem control on stack
	io_delay
	in	al,dx
	push	ax

	mov	ch,3			;--> fast reset value
	call	test_loop		;Try fast reset
	jnc	got_card		;Found a fast serial port
	mov	ch,9			;--> slow reset value
	call	test_loop		;Try slow reset
	jnc	got_card		;Found a slow serial port

	lea	dx,[di].ACE_MCR 	;Restore modem control
	pop	ax
	out	dx,al

	lea	dx,[di].ACE_IER 	;Restore interrupt enable
	pop	ax
	out	dx,al

	lea	dx,[di].ACE_LCR 	;Enable divisor access
	mov	al,ACE_DLAB
	io_delay
	out	dx,al

	lea	dx,[di].ACE_DLL 	;Restore lsb of divisor
	pop	ax
	out	dx,al

	lea	dx,[di].ACE_DLM 	;Restore msb of divisor
	pop	ax
	out	dx,al

	lea	dx,[di].ACE_LCR
	pop	ax			;Restore line control
	out	dx,al
	mov	bh,80h			;Show not found
	jmp	short restore_8259

got_card:
	add	sp,5*2			;Clear all the saved parameters
	xor	bh,bh			;Show found

restore_8259:
	mov	ah,mask_8259		;Get our enable mask
	cli
	in	al,MASK_PORT		;Get current 8259 mask
	and	al,ah			;Remove our IRQ bit
	or	al,bl			;Restore old IRQ bit
	out	MASK_PORT,al
	sti

	shl	bh,1			;Set/clear carry as appropriate
	ret

test_card	endp
page

;---------------------------Private-Routine-----------------------------;
; test_loop - Test Serial Card For A Mouse
;
; Test loop cycles the power to the serial mouse, delays while
; waiting for it to power up, then waits for the mouse to return
; an 'M'.  If an 'M' is returned withing the alloted time, a mouse
; has been found.  IF not, no mouse has been found.
;
; Entry:
;	DI = port base address
;	CH = # timer ticks to delay while flushing
; Returns:
;	'C' clear if found
;	'C' set   if not found
; Error Returns:
;	None
; Registers Preserved:
;	BX,SI,DS,BP
; Registers Destroyed:
;	AX,CX,DX,DI,ES,FLAGS
; Calls:
;	None
; History:
;	Wed 02-Sep-1987 14:43:29 -by-  Walt Moore [waltm]
;	Load new timer before entering flush_loop_2
;
;	Mon 24-Aug-1987 23:54:02 -by-  Walt Moore [waltm] & Mr. Mouse
;	Initial version
;-----------------------------------------------------------------------;

;------------------------------Pseudo-Code------------------------------;
; {
; }
;-----------------------------------------------------------------------;

	assumes cs,Code
	assumes ds,Data

		public	test_loop	;Public for debugging
test_loop	proc	near

	lea	dx,[di].ACE_MCR 	;Set DTR & reset RTS
	mov	al,ACE_DTR
	out	dx,al

	mov	ax,BIOSDataSeg
	mov	es,ax
	assumes es,BIOSDataSeg

	mov	cl,bios_time		;Flush 8250 receive buffer
	lea	dx,[di].ACE_RBR
	in	al,dx			;Flush a character

flush_loop_1:
	cmp	cl,bios_time		;Wait 0-55 milliseconds
	je	flush_loop_1
	mov	ah,ch			;Count this many timer ticks
	inc	ah			;First cmp will fail, so adjust for it
	io_delay
	in	al,dx			;Flush a character

flush_loop_2:
	cmp	cl,bios_time		;Wait 55 or 330 milliseconds
	je	flush_loop_2
	mov	cl,bios_time
	dec	ah
	jnz	flush_loop_2
	in	al,dx			;Flush a character

flush_loop_3:
	cmp	cl,bios_time		;Wait 55 milliseconds
	je	flush_loop_3
	lea	dx,[di].ACE_LSR 	;Clear error flags
	in	al,dx

	lea	dx,[di].ACE_MCR 	;Power up the mouse
	mov	al,ACE_DTR+ACE_RTS
	io_delay
	out	dx,al


;	Read 3 characters looking for capital M sent by mouse

	mov	ch,3+1			;Try first three characters

not_M:					;Character read wasn't an M
	dec	ch			;Decrement remaining tries counter
	jz	no_M_found		;Out of attempts

read_loop:
	lea	dx,[di].ACE_LSR 	;--> status port
	mov	ah,'M'			;Capacitance will keep 'M" floating
	mov	cl,bios_time		;  on data bus if a CMP AL,'M' is used

read_loop_1:
	io_delay
	in	al,dx			;--> status
	test	al,ACE_DR		;Check if character available
	jnz	got_char		;Character available
	cmp	cl,bios_time		;Check for 0-55 milliseconds
	je	read_loop_1
	mov	cl,bios_time

read_loop_2:
	io_delay
	in	al,dx			;--> status
	test	al,ACE_DR		;Check if character available
	jnz	got_char		;Character available
	cmp	cl,bios_time		;Check for 0-55 milliseconds
	je	read_loop_2

no_M_found:
	stc				;No mouse
	ret

got_char:
	lea	dx,[di].ACE_RBR 	;Have a character.  It must be
	io_delay			;  an M if it's our mouse
	in	al,dx
	cmp	al,ah
	jne	not_M			;Not an "M"
;	clc				;Got it!!!!
	ret

test_loop	endp

sEnd	Code
end