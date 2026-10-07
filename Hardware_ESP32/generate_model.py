import os
import tensorflow as tf
from tensorflow.keras import layers
import numpy as np

# 1. Create a tiny dummy model for 128 frequency bins
model = tf.keras.Sequential([
    layers.Input(shape=(128,)),
    layers.Dense(16, activation='relu'),
    layers.Dense(3, activation='softmax')
])

# 2. Compile and give it dummy weights
model.compile(optimizer='adam', loss='sparse_categorical_crossentropy')
dummy_x = np.random.random((10, 128)).astype(np.float32)
dummy_y = np.random.randint(0, 3, (10,))
model.fit(dummy_x, dummy_y, epochs=1, verbose=0)

# 3. Convert to TFLite
converter = tf.lite.TFLiteConverter.from_keras_model(model)
converter.optimizations = [tf.lite.Optimize.DEFAULT]
tflite_model = converter.convert()

# 4. Convert TFLite model to C++ array
hex_array = ', '.join([f"0x{b:02x}" for b in tflite_model])
cpp_code = f'''#ifndef MODEL_DATA_H
#define MODEL_DATA_H

// Auto-generated TFLite model
const unsigned char g_model_data[] = {{
    {hex_array}
}};
const int g_model_data_len = {len(tflite_model)};

#endif
'''

with open('include/model_data.h', 'w') as f:
    f.write(cpp_code)

print("Generated include/model_data.h successfully!")