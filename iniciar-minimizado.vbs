' ---------------------------------------------------------------------------
' Arranca el agente de impresion sin la ventana negra en la cara del operador.
'
' El agente es un proceso que corre todo el dia consultando la cola, asi que
' tiene que quedar prendido; lo que no tiene que hacer es ocupar la pantalla
' del PDV. Este lanzador lo deja MINIMIZADO, no oculto, a proposito:
'
'   - minimizado: queda en la barra de tareas. El operador lo abre si quiere
'     ver que esta pasando, y lo cierra para detenerlo.
'   - oculto (0): mas limpio, pero no habria forma de verlo ni de detenerlo
'     sin el Administrador de tareas.
'
' Si preferis que no se vea en absoluto, cambie el 7 por un 0 mas abajo.
' ---------------------------------------------------------------------------

Option Explicit

Dim fso, sh, carpeta, bat, ini

Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")

carpeta = fso.GetParentFolderName(WScript.ScriptFullName)
bat     = carpeta & "\iniciar.bat"
ini     = carpeta & "\agente.ini"

' Sin agente.ini el .bat hace "pause" esperando una tecla. Minimizado eso queda
' trabado sin que nadie entienda por que, entonces se avisa aca y no se lanza.
If Not fso.FileExists(ini) Then
    MsgBox "Falta el archivo agente.ini." & vbCrLf & vbCrLf & _
           "La computadora no quedo vinculada al sistema. Desinstale el agente," & vbCrLf & _
           "genere un codigo nuevo en Impresion -> Agentes de impresion e instale" & vbCrLf & _
           "de nuevo.", vbExclamation, "Agente de Impresion NEOSYSTEM"
    WScript.Quit 1
End If

If Not fso.FileExists(bat) Then
    MsgBox "Falta el archivo iniciar.bat. Reinstale el agente.", _
           vbExclamation, "Agente de Impresion NEOSYSTEM"
    WScript.Quit 1
End If

' 7 = minimizado y sin robar el foco. False = no esperar: este script termina y
' el agente sigue corriendo.
sh.Run """" & bat & """", 7, False
