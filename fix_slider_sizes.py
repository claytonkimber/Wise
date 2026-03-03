import re

def process_file(filename):
    with open(filename, "r") as f:
        content = f.read()

    # We need to find all slider:SetSize(X, Y) and standardize them to 126
    # 126 + 27 + 27 = 180 (the original total width of the elements without clipping)

    # Let's fix the slider sizes
    content = re.sub(r'(\w+Slider):SetSize\(\d+,\s*16\)', r'\1:SetSize(126, 16)', content)

    # Also standardize SetPoint X offsets for the sliders to 37 (to give room for the 27px button on the left without breaking 10px margin)
    content = re.sub(r'(\w+Slider):SetPoint\("TOPLEFT",\s*\d+,\s*([^\)]+)\)', r'\1:SetPoint("TOPLEFT", 37, \2)', content)

    # Let's also make sure we didn't duplicate nudger buttons for radSlider/rotSlider
    # In Properties.lua we previously added `radMinusBtn` and `rotMinusBtn`. The script probably added `radSliderMinusBtn` and `rotSliderMinusBtn`.

    # Let's completely remove the auto-generated ones for radSlider and rotSlider if they exist.
    if filename == "modules/Properties.lua":
        # Remove auto-generated radSlider nudgers
        content = re.sub(r'-- Minus Button for radSlider.*?end\)\n\s*tinsert\(panel\.controls, radSliderMinusBtn\)\n', '', content, flags=re.DOTALL)
        content = re.sub(r'-- Plus Button for radSlider.*?end\)\n\s*tinsert\(panel\.controls, radSliderPlusBtn\)\n', '', content, flags=re.DOTALL)

        # Remove auto-generated rotSlider nudgers
        content = re.sub(r'-- Minus Button for rotSlider.*?end\)\n\s*tinsert\(panel\.controls, rotSliderMinusBtn\)\n', '', content, flags=re.DOTALL)
        content = re.sub(r'-- Plus Button for rotSlider.*?end\)\n\s*tinsert\(panel\.controls, rotSliderPlusBtn\)\n', '', content, flags=re.DOTALL)

    with open(filename, "w") as f:
        f.write(content)

process_file("modules/Properties.lua")
process_file("modules/Settings.lua")
print("Done fixing slider sizes and positions")
