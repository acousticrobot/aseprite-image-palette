## Asprite Image Palette

I like to organize my palettes in two dimensions, so I can keep track of color ramps. This plug-in places an additional view of the current palette below the standard one, when the palette is loaded from an image. You can choose a color from any of the already available methods, or directly from the custom palette. Like the standard palette, the current color is indicated in this palette as well.

This view is still designed for loading palettes where each color is represented by a single pixel, so images are limited to 96×96 pixels. Each pixel is drawn as a cell between 4 and 32 px wide. The view starts a little under 320 px on its longest side, so an image wider or taller than about 40 pixels starts at the 4 px minimum, which is hard to click (press + to enlarge). Indexed sprites hold at most 256 colors, so an image with more unique colors than that can't replace an indexed sprite's palette (it can still be shown and picked from).

Fully transparent pixels are left as empty cells, so you can use them to space out ramps.

## To Add to Asprite

Requires Aseprite 1.3 or later.

1. Build the extension package:

   ```bash
   ./build.sh
   ```

2. Double-click `dist/image-palette.aseprite-extension`, or in Aseprite go to **Edit > Preferences > Extensions > Add Extension** and choose that file.

## To use

1. Open the palette options menu (the ☰ button above the palette) and choose **Load Palette from Image (2D)...**.
2. Pick an image where each pixel is one palette color (`examples/example-1.png` is a small sample). Leave **Replace the current palette** checked to also load the colors into the standard palette. Duplicate colors are only added once.
   - **Order**: *Reading order* adds colors left to right, top to bottom. *Aseprite default* uses the same order as Aseprite's own **Load Palette** (its color quantization).
   - **Include transparent color**: when the image has transparent pixels, adds a transparent entry at index 0, as Aseprite's **Load Palette** does. Uncheck it to keep transparent pixels purely for layout. (Aseprite's **Load Palette** adds the transparent entry even to images with no transparent pixels; this plugin only adds it when the image has some.)
3. The Image Palette window opens under the color bar. Drag it wherever you like; it reopens in the same place.
   - **Left-click** a cell to set the foreground color, **right-click** to set the background color.
   - The current foreground color is marked with a triangle in the top-left corner of its cell and the background color in the bottom-right, like the standard palette. The markers update however the color was picked. When a color appears more than once, only one cell is marked: the one you clicked, or else the first one in reading order.
   - Hover a cell to see its hex value and position. Use **-** / **+** to change the cell size.
4. **Show/Hide Image Palette** in the same menu toggles the window and reloads the last image (it's read again from disk, so edits to the image show up).


### Roadmap

- [x] Adjust the default palette size so that it is only as wide as the current palette area.
- [x] Load colors in the same order as the default palette
- [x] Only indicate the first instance of a color as selected (too noisy for loading an image as a palette to show all)
- [ ] Should we have one palette window per open file?
- [x] Limit loading images to a reasonable size
- [x] Include transparent pixels if they exist



