#   Microsoft Mouse Driver
#
#   Requirements:
#
#	MASM 4.01 or greater with the environment variable INCLUDE set to
#	the directories containing CMACROS.INC, and WINDEFS.INC.
#
#	MASM 4.00 or greater with the ASM inference definition changed to
#	include the directories containing CMACROS.INC, and WINDEFS.INC.


#   Options:
#
#	The command line may define options to MASM by defining the OPT
#	macro.	By defining the OPT parameter in the make file, any
#	possible interaction with an environment definition is avoided.

OPT = -l				    #NOP the options feature


#   Define the default assemble command.  This command could actually
#   be overridden from the command line, but shouldn't be.

ASM = masm -v -ML  $(OPT)					# MASM 4.01 & >
#   ASM = masm -v -ML  $(OPT) -I\finc				# MASM 4.00


#   Define the default inference rules

.asm.obj:
	$(ASM) $*,$@;

vmwmouse:  vmwmouse.drv

mouse.obj:	mouse.asm mouse.inc

ps2.obj:	ps2.asm mouse.inc

vmwmouse.drv:	mouse.def mouse.obj ps2.obj
      link @mouse.lnk
      rc vmwmouse.drv
      mapsym vmwmouse
