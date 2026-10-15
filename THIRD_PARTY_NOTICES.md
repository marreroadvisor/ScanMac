# Licencias y procedencia

El código Swift/Python de la aplicación, los catálogos de interfaz, el icono SM y las ilustraciones SVG/CSS de ScanMac se distribuyen bajo la licencia MIT del proyecto. Los frameworks y símbolos del sistema de Apple se utilizan mediante sus APIs y no se redistribuyen como frameworks propios.

## Modelos opcionales

- **Community Forensics**, Jeongsoo Park / OwensLab: [implementación](https://github.com/s-jyeon/CommunityForensicsTrain), [pesos](https://huggingface.co/OwensLab/commfor-model-384), MIT. El aviso completo se conserva en `Engines/licenses/CommunityForensics-MIT.txt`. La arquitectura y el preprocesado se adaptan a ejecución local con pesos safetensors.
- **LaMa**, Roman Suvorov y colaboradores: [proyecto](https://github.com/advimman/lama), Apache-2.0. Licencia completa en `Engines/licenses/LaMa-Apache-2.0.txt`. El archivo TorchScript se obtiene del [distribuidor IOPaint](https://github.com/Sanster/IOPaint/blob/main/iopaint/model/lama.py). Se documentan URL y SHA-256 en `Engines/models.json`.

No se incluyen pesos en el repositorio. Las dependencias Python se descargan por separado desde PyPI y conservan sus propias licencias, incluidas PyTorch, torchvision, timm, safetensors, OpenCV, NumPy, Pillow y huggingface-hub. Sus paquetes instalados incluyen los avisos correspondientes. Codex CLI y LM Studio se instalan por separado y no se redistribuyen aquí.

No se distribuyen los archivos de prueba públicos descargados durante el desarrollo ni datos personales de usuarios. Las ilustraciones de herramientas son propias y no requieren Lottie ni imágenes incrustadas de terceros.
