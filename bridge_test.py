import os
import sys
import time

# Use the in-repo package (python/kaos_cleaner) without installing it. It picks
# the right binary for this OS and finds the runtime in kaos_binaries/.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "python"))

from kaos_cleaner import clean_csv  # noqa: E402

# --- Run the Test ---
if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "dummy.csv"

    start = time.time()
    df = clean_csv(path)
    end = time.time()

    print(f"Success! Processed in {end - start:.4f} seconds.")
    print(df)
