# Windows distribution notices

The Windows preview references NAudio 2.3.0 and System.Security.Cryptography.ProtectedData 10.0.0. Self-contained builds also include the Microsoft .NET / Windows Desktop runtime. Apple-specific dependencies in the repository's root THIRD-PARTY-NOTICES.md are not part of the Windows app.

## NAudio (MIT)

Source: https://github.com/naudio/NAudio/tree/v2.3.0

Copyright 2020 Mark Heath

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Microsoft .NET and System.Security.Cryptography.ProtectedData

Copyright (c) .NET Foundation and Contributors.

The .NET source repositories use the MIT license reproduced below. Microsoft distribution terms and bundled third-party notices are included as `DOTNET-LICENSE.txt` and `DOTNET-ThirdPartyNotices.txt` alongside the self-contained executable.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Source: https://github.com/dotnet/runtime and https://github.com/dotnet/wpf

## Test-only dependencies

xUnit.net and its Visual Studio runner (Apache-2.0), and Microsoft.NET.Test.Sdk (MIT) are used by the test project. They are not shipped in the application. Exact direct and transitive package versions are recorded in each project's `packages.lock.json`.

## Whisper.net 1.9.1 and whisper.cpp (MIT)

Whisper.net copyright (c) 2024 sandrohanea. Native whisper.cpp copyright (c) 2023-2024 The ggml authors. Full MIT notices are shipped in `licenses/WHISPER-NET-LICENSE.txt` and `licenses/WHISPER-CPP-LICENSE.txt`. The Windows CPU and CUDA12 native libraries come from the pinned Whisper.net.Runtime and Whisper.net.Runtime.Cuda12.Windows NuGet packages. See https://github.com/sandrohanea/whisper.net and https://github.com/ggml-org/whisper.cpp.

## Optional model/runtime downloads

The app ZIP does not include model weights, Ollama, or llama-server. The model-preparation action downloads them from the original publishers. Pinned URLs, byte sizes and SHA-256 values for Whisper, Qwen3-ASR and executable archives are in ModelDownload.cs, QwenTranscriber.cs and LocalRuntime.cs. Ollama validates model content by registry digest.

- Whisper large-v3-turbo weights: MIT, https://github.com/openai/whisper and https://huggingface.co/openai/whisper-large-v3-turbo.
- Qwen3-ASR 0.6B/1.7B and Qwen3.5 4B/9B: Apache-2.0, publisher model cards at https://huggingface.co/Qwen. GGUF conversions: https://huggingface.co/ggml-org.
- Ollama v0.34.0: MIT, https://github.com/ollama/ollama/tree/v0.34.0. Preserve the notices in its downloaded `lib/ollama` directory.
- llama.cpp b10809: MIT, copyright (c) 2023-2026 The ggml authors. A full notice is included in `licenses/LLAMA-CPP-LICENSE.txt`; preserve notices from the downloaded archive.
- NVIDIA CUDA/cuBLAS/cuDNN redistributable libraries have NVIDIA terms, not the MIT license. These are downloaded with the official runtime archives when needed; retained vendor notices include `CUDNN_LICENSE.txt` in the Ollama distribution. See https://docs.nvidia.com/cuda/eula/ for CUDA terms.

Downloaded third-party tools and weights are stored separately from recordings. Do not remove or relicense their publisher notices when redistributing them.
