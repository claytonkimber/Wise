import re

def main():
    with open("modules/Properties.lua", "r") as f:
        props = f.read()

    # The code review mentioned that piTextSliderMinusBtn and piTextSliderPlusBtn are INSIDE the OnValueChanged event handler.
    # We need to move them out. Let's find this section.

    match = re.search(r'(piTextSlider:SetScript\("OnValueChanged", function\(self, value\).*?end\))(.*?)tinsert\(panel\.controls, piTextSlider\)', props, re.DOTALL)
    if match:
        script_block = match.group(1)
        buttons_block = match.group(2)

        # We want to insert the buttons_block AFTER the tinsert
        # But wait, the buttons_block currently is inside the OnValueChanged? Let's check exactly where they are.
        pass

    # Let's just find the buttons block manually
    buttons_pattern = r'(\s*-- Minus Button for piTextSlider.*?tinsert\(panel\.controls, piTextSliderPlusBtn\))'
    match_btns = re.search(buttons_pattern, props, re.DOTALL)
    if match_btns:
        buttons_text = match_btns.group(1)

        # Where are they currently? Let's see if they are inside the function
        # Actually, let's just remove them from wherever they are, and put them after `tinsert(panel.controls, piTextSlider)`
        props = props.replace(buttons_text, "")

        insert_pos = props.find('tinsert(panel.controls, piTextSlider)')
        if insert_pos != -1:
            end_of_line = props.find('\n', insert_pos)
            props = props[:end_of_line+1] + buttons_text + props[end_of_line+1:]

    with open("modules/Properties.lua", "w") as f:
        f.write(props)

    # Now for Settings.lua. The regex in fix_slider_sizes.py failed because the point X is not a digit, it's `rx`.
    # Original: iconSlider:SetPoint("TOPLEFT", rx, ry)
    # Original Size: iconSlider:SetSize(180, 16)

    with open("modules/Settings.lua", "r") as f:
        settings = f.read()

    # Fix sizes
    settings = re.sub(r'(\w+Slider):SetSize\(\d+,\s*16\)', r'\1:SetSize(126, 16)', settings)

    # Fix positions: change SetPoint("TOPLEFT", rx, ry) to SetPoint("TOPLEFT", rx + 30, ry)
    # Wait, rx is already a variable. We can do `rx + 27`
    settings = re.sub(r'(\w+Slider):SetPoint\("TOPLEFT",\s*rx,\s*ry\)', r'\1:SetPoint("TOPLEFT", rx + 27, ry)', settings)

    with open("modules/Settings.lua", "w") as f:
        f.write(settings)

    print("Fixed text slider bug and settings layout.")

if __name__ == "__main__":
    main()
