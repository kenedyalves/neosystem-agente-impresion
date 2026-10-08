# Agente de Impresión NEOSYSTEM

Programa para Windows que permite imprimir tickets directamente en la impresora térmica
cuando el sistema NEOSYSTEM está en internet.

## Descargar

**[⬇ Descargar instalador para Windows](https://github.com/kenedyalves/neosystem-agente-impresion/releases/latest/download/neosystem-agente-impresion.exe)**

No hace falta instalar nada más: el instalador ya trae todo lo necesario.

## Cómo instalar

1. En el sistema: menú → **Agentes de impresión** → **Agregar impresora**.
   Aparece un código de 6 caracteres, válido por 15 minutos.
2. En la computadora que tiene la impresora, descargue y ejecute el instalador.
3. En la pantalla "Conectar con el sistema" escriba:
   - la **dirección del sistema** (la misma que usa en el navegador);
   - el **código** de 6 caracteres.
4. Listo. El agente se configura solo y arranca junto con Windows.

### Instalación sin pantallas (varias sucursales)

```
neosystem-agente-impresion.exe /VERYSILENT /CODIGO=4F2K9B /URL=https://suempresa.com
```
