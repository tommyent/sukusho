# Real capture fixture

`capture-library-light.png` is a 500 × 470 crop of a real screenshot of this app's Library window in light
mode, taken on a test Mac with test captures in it: the right-hand thumbnails and the inspector. It is mostly
neutral grays with small colored parts (red annotation text, a blue link, colored thumbnails), which is what
the image optimizer's tests need it for. It holds no personal data and no metadata, and was made smaller with
`oxipng -o 4 --strip safe`.

The optimizer's tests use it as it is, and enlarged past one million pixels and written as a JPEG, the size
from which ImageIO decodes baseline and progressive JPEGs with different code.
