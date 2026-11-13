from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED


def main():
    root = Path(__file__).resolve().parent.parent
    files = ["README.md", "Dockerfile", "compose.yaml", "compose.https.yaml", ".env.example",
             ".gitignore", ".dockerignore", "alembic.ini", "requirements.in", "requirements.txt",
             "requirements-dev.txt", "pytest.ini", "Avvia-demo.cmd", "Ferma-demo.cmd", "Apri-piattaforma-VM.cmd"]
    for directory in ["app", "migrations", "model_integration", "scripts", "docs", "tests", "ops", "training"]:
        for path in (root / directory).rglob("*"):
            if not path.is_file() or "__pycache__" in path.parts or path.suffix in {".pyc", ".pyo"}:
                continue
            if "weights" in path.parts and path.name != ".gitkeep":
                continue
            files.append(path.relative_to(root).as_posix())
    files = [name for name in files if (root / name).is_file()]
    output = root / "telederm-progetto.zip"
    with ZipFile(output, "w", compression=ZIP_DEFLATED) as archive:
        for name in sorted(files):
            archive.write(root / name, name)
    print(f"Pacchetto creato: {output}")
    print(f"{len(files)} file; esclusi credenziali, database, foto caricate, ambiente locale e pesi del modello.")


if __name__ == "__main__":
    main()
