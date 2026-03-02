import os

# Root directory to start from
root_dir = "."

# Output file
output_file = "kustomizations_combined.txt"

with open(output_file, "w") as out_f:
    for dirpath, _, filenames in os.walk(root_dir):
        for filename in filenames:
            if filename == "kustomization.yaml":
                full_path = os.path.join(dirpath, filename)
                out_f.write(f"{full_path}\n")  # Write full path
                out_f.write("-" * 5 + "\n")   # Separator
                with open(full_path, "r") as f:
                    out_f.write(f.read())      # Write file contents
                out_f.write("\n\n")            # Extra spacing between files

print(f"All kustomization.yaml files combined into {output_file}")
